"""
Docs building blocks: a project-wide symbol index (the Julia analog of
nbdev's `doclinks.py` / `_modidx.py`) and `show_doc` (nbdev's
`showdoc.py`).

`show_doc` needs almost none of the machinery nbdev's Python version
does. Python has no structural per-argument doc syntax, so nbdev/fastcore
built "docments" — parsing a trailing `# comment` after each parameter
across a multi-line signature — just to get a parameter table. Julia
docstrings are already structured text attached to a name via the `@doc`
system; `show_doc` just has to *fetch and format* that text, not
reconstruct it from source. Concretely: `@doc name` (evaluated via
`Core.eval(mod, Meta.parse("@doc " * name))`) returns a `Base.Docs.DocStr`
whose `.text` field is the raw docstring — join it and that's the body.

The symbol index reuses `Export`'s AST walk (`toplevel_exprs`/
`toplevel_names`) rather than duplicating it — the same question
("what name does this top-level form introduce?") is being asked for a
different purpose (where is a name documented, not what goes in
`export`).

`render_notebook` renders straight to Quarto markdown (`.qmd`) text rather
than mutating notebook cells the way nbdev's processor pipeline does —
there's no live notebook structure to preserve once the target is a
rendered page, so the per-cell decisions nbdev spreads across several
processors (`add_show_docs`, `rm_export`, `add_fold`, `hide_`) collapse
into one `plan_cell` call per cell. Known simplification, same spirit as
`NbTest`: only a cell's *computed value* is captured, not printed stdout/
stderr (an `IOBuffer` isn't a valid `redirect_stdout` target in Base, and
building a `Pipe`-based capture wasn't worth it after this project's
earlier self-import deadlock — see `NbTest.jl`). A `println`-only cell
renders no output block; an explicit `show_doc(...)` call or a cell whose
last expression evaluates to something, does.
"""
module NbDocs

export SymbolEntry, build_symbol_index, show_doc, render_notebook, plan_cell, CellPlan

using Markdown

using ..Config
using ..NbIO
using ..NbTest: does_cell_eval
using ..Export: toplevel_exprs, toplevel_names

# ---------------------------------------------------------------------------
# Symbol index
# ---------------------------------------------------------------------------

"Where a name is defined: which generated library file, and which source notebook cell it came from."
struct SymbolEntry
    name::String
    src_file::String  # relative to cfg.src_path
    nb_file::String   # relative to cfg.nbs_path
    cell_id::String
end

"""
    iter_provenance_chunks(path)

Yield `(nb_relpath, cell_id, code)` for each provenance-tagged chunk of a
generated `.jl` file at `path` — i.e. each `# %% <nb_relpath> #<cell_id>`
header `Export.write_module` wrote, paired with the code that follows it
up to the next header (or EOF). `nb_relpath` is relative to `path`'s own
directory, exactly as written.
"""
function iter_provenance_chunks(path::AbstractString)
    text = read(path, String)
    parts = split(text, "\n# %% ")
    chunks = Tuple{String,String,String}[]
    for part in parts[2:end]
        nl = findfirst('\n', part)
        nl === nothing && continue
        top = part[1:(nl - 1)]
        code = part[(nl + 1):end]
        sp = findlast(' ', top)
        (sp === nothing || !startswith(top[(sp + 1):end], "#")) && continue
        nb = top[1:(sp - 1)]
        cellid = top[(sp + 2):end]
        push!(chunks, (nb, cellid, code))
    end
    return chunks
end

"""
    build_symbol_index(cfg)

Scan every `.jl` file under `cfg.src_path` and return
`Dict{String,SymbolEntry}` mapping each name nbdev-exported code
defines to where it came from. Last writer wins if (unusually) the same
name is defined in two places. Not a full equivalent of nbdev's
cross-package `_modidx.py` lookup (no `entry_points`-based lookup across
other installed nbdev packages) — just this project's own symbols, for
now.
"""
function build_symbol_index(cfg::Config.NBConfig)
    idx = Dict{String,SymbolEntry}()
    root = cfg.d["src_path"]
    isdir(root) || return idx
    for (dir, _, files) in walkdir(root)
        for f in files
            endswith(f, ".jl") || continue
            full = joinpath(dir, f)
            relsrc = relpath(full, root)
            for (nbrel, cellid, code) in iter_provenance_chunks(full)
                nbrel == "auto" && continue
                nbabs = normpath(joinpath(dirname(full), nbrel))
                nbdisplay = relpath(nbabs, cfg.d["nbs_path"])
                for expr in toplevel_exprs(code)
                    for nm in toplevel_names(expr)
                        idx[nm] = SymbolEntry(nm, relsrc, nbdisplay, cellid)
                    end
                end
            end
        end
    end
    return idx
end

# ---------------------------------------------------------------------------
# show_doc
# ---------------------------------------------------------------------------

_doc_name(x::Union{AbstractString,Symbol}) = string(x)
function _doc_name(x)
    try
        return string(nameof(x))
    catch
        return string(x)
    end
end

_doc_module(x, default::Module) = default
function _doc_module(x::Union{Function,Type}, default::Module)
    try
        return parentmodule(x)
    catch
        return default
    end
end

"""
    show_doc(x; mod=Main, title_level=3, index=nothing)

Markdown-rendered signature + docstring for `x` — a function, type, or
macro already in scope (e.g. `show_doc(foo)`), or a name as a `String`/
`Symbol` to look up in `mod`. Returns a `Markdown.MD`.

Pass `index` (a `Dict{String,SymbolEntry}` from `build_symbol_index`) to
append a "defined in `<notebook>` (cell `<id>`)" line when the name is
one nbdev exported — the Julia analog of nbdev's source-link.
"""
function show_doc(
    x;
    mod::Module = Main,
    title_level::Int = 3,
    index::Union{Nothing,Dict{String,SymbolEntry}} = nothing,
)
    nm = _doc_name(x)
    lookupmod = _doc_module(x, mod)
    d = try
        # Built as an `Expr`, not `Meta.parse("@doc " * nm)`: a name that
        # collides with a Julia keyword (e.g. a function named `export`,
        # only reachable via `var"export"`) fails to parse as a bare `@doc
        # <name>` string, and that failure was silently swallowed by the
        # surrounding try/catch, always falling through to "no docstring
        # found" even when a real one exists (confirmed by a stress-test
        # agent). Building `Mod.name` directly as a qualified-access `Expr`
        # (not through the parser at all) sidesteps the keyword lexing
        # issue entirely, and — confirmed empirically — also correctly
        # resolves to the user's own binding rather than Julia's built-in
        # documentation for the keyword itself, which a bare `Symbol(nm)`
        # lookup prefers whenever `nm` happens to also be a keyword.
        qualified = Expr(:., lookupmod, QuoteNode(Symbol(nm)))
        Core.eval(lookupmod, Expr(:macrocall, Symbol("@doc"), LineNumberNode(@__LINE__, Symbol(@__FILE__)), qualified))
    catch
        nothing
    end
    # `@doc` returns a `DocStr` (real docstring text), a `Markdown.MD`
    # (its own "no documentation found for ..." fallback, already nicely
    # formatted with method/source info), or `nothing` (name not found
    # at all — `@doc` doesn't error on an unknown name).
    body = if d === nothing
        Markdown.parse("*No docstring found.*")
    elseif d isa Base.Docs.DocStr
        Markdown.parse(join(d.text))
    else
        d
    end
    parts = Any[Markdown.parse("#"^title_level * " `" * nm * "`"), body]
    if index !== nothing && haskey(index, nm)
        e = index[nm]
        push!(parts, Markdown.parse("*Defined in `$(e.nb_file)` (cell `$(e.cell_id)`).*"))
    end
    return Markdown.MD(parts...)
end


# ---------------------------------------------------------------------------
# Auto show_doc insertion + per-cell visibility (nbdev's add_show_docs +
# rm_export + add_fold + hide_, combined into one decision per cell since
# nbdev renders straight to text rather than mutating notebook cells)
# ---------------------------------------------------------------------------

"How one cell participates in a rendered docs page."
struct CellPlan
    visible::Bool              # false for `#| hide` — nothing from this cell appears, but it still runs
    show_source::Bool          # false for #|export/#|exporti/#|exportd/#|default_exp (nbdev's rm_export)
    fold::Bool                 # true for #|exports — shown, but in a collapsible fold (nbdev's add_fold)
    auto_names::Vector{String} # public names to auto-`show_doc` right after this cell
end

const _SOURCE_HIDDEN_DIRS = ("export", "exporti", "exportd", "default_exp")
const _PUBLIC_EXPORT_DIRS = ("export", "exports")

"""
    explicitly_shown_names(nb)

Names already passed to a bare `show_doc(name)` call anywhere in the
notebook (e.g. `show_doc(foo)`, `show_doc(:foo)`, `show_doc("foo")`) —
these are excluded from auto-insertion, matching nbdev's own dedup
("unless they are already documented"). Simplification vs. nbdev: only
bare calls are recognized, not a qualified `NBDev.show_doc(...)` form.
"""
function explicitly_shown_names(nb)
    shown = Set{String}()
    for cell in get(nb, "cells", Any[])
        get(cell, "cell_type", "") == "code" || continue
        src = NbIO.cell_source(cell)
        src === nothing && continue
        for expr in toplevel_exprs(src)
            nm = _show_doc_call_arg(expr)
            nm === nothing || push!(shown, nm)
        end
    end
    return shown
end

function _show_doc_call_arg(expr)
    (expr isa Expr && expr.head === :call) || return nothing
    expr.args[1] === :show_doc || return nothing
    length(expr.args) >= 2 || return nothing
    arg = expr.args[2]
    arg isa Symbol && return string(arg)
    (arg isa QuoteNode && arg.value isa Symbol) && return string(arg.value)
    arg isa AbstractString && return arg
    return nothing
end

"""
    plan_cell(cell, already_documented)

Decide how `cell` participates in a rendered docs page (see `CellPlan`).
`already_documented` is a `Set{String}` this call may both read (names
already explicitly `show_doc`'d) and extend (names this cell just got
auto-assigned, so a later export of the same name — unusual, but
possible — doesn't get a second entry); share one `Set` across all cells
of a notebook when planning it in order.
"""
function plan_cell(cell, already_documented::Set{String})
    dirs = NbIO.cell_directives(cell)
    visible = !haskey(dirs, "hide")
    show_source = !any(d -> haskey(dirs, d), _SOURCE_HIDDEN_DIRS)
    fold = haskey(dirs, "exports")
    auto_names = String[]
    want_doc = visible && get(cell, "cell_type", "") == "code" && any(d -> haskey(dirs, d), _PUBLIC_EXPORT_DIRS)
    if want_doc
        src = NbIO.cell_source(cell)
        if src !== nothing
            for expr in toplevel_exprs(NbIO.strip_directive_lines(src))
                for nm in toplevel_names(expr)
                    (startswith(nm, "_") || nm in already_documented) && continue
                    push!(auto_names, nm)
                    push!(already_documented, nm)
                end
            end
        end
    end
    return CellPlan(visible, show_source, fold, auto_names)
end

# ---------------------------------------------------------------------------
# Rendering a notebook to Quarto markdown
# ---------------------------------------------------------------------------

"""
Would evaluating `expr` at the Julia REPL print a result worth showing, or
is it just a silent-in-spirit definition (`function`/`struct`/`abstract
type`/`primitive type`/`macro`, or a short-form function def `foo(x) =
...`) whose *value* is merely an echo of the thing just defined? Python's
`def`/`class` statements aren't expressions at all, so nbdev never has to
make this distinction — Julia's equivalent forms *are* expressions that
evaluate to a value (the function/type object), which would otherwise
show up as redundant noise right next to that same name's auto-inserted
`show_doc` card. A plain assignment (`DEFAULT_TIMEOUT = 30`) is *not*
treated as silent — its value is exactly what's useful to show.
"""
function is_silent_definition(expr)
    expr isa Expr || return false
    h = expr.head
    if h in (:block, :toplevel)
        # `:toplevel` is how `Meta.parse` wraps a statement followed by a
        # trailing `;` (confirmed empirically); `:block` is a `begin...end`
        # grouping. Either way, judge silence by the last real statement —
        # the same thing Julia itself would actually evaluate to.
        stmts = filter(a -> !(a isa LineNumberNode), expr.args)
        return !isempty(stmts) && is_silent_definition(last(stmts))
    end
    h === :macrocall && return is_silent_definition(expr.args[end])
    h === :const && return is_silent_definition(expr.args[1])
    h in (:function, :struct, :abstract, :primitive, :macro) && return true
    h === :(=) && return expr.args[1] isa Expr && expr.args[1].head === :call
    return false
end

"""
    render_notebook(nbpath, cfg; index=build_symbol_index(cfg), default_eval=true,
                     skip_flags=Set(["notest"]), force_flags=Set{String}())

Render notebook `nbpath` to a Quarto-markdown (`.qmd`) string: executes
its code cells in document order, in a fresh sandbox module (same
`Core.eval`+`Meta.parseall` approach as `NbTest.test_nb`, same eval-
participation cascade via `NbTest.does_cell_eval` — `skip_flags`/
`force_flags` default to the exact same values `test_nb`/`test_project`
use, so a `#| notest` cell is skipped here too, not just during testing;
this used to default to always-empty sets, so `#| notest` was silently
*ignored* during docs rendering even though `test_project` correctly
skipped the same cell — confirmed by a stress-test agent, and a direct
contradiction of this very docstring's own claim), and for each cell:

- a markdown cell's source is emitted as-is (unless `#| hide`);
- a code cell's source is emitted as a fenced `julia` block unless its
  directives hide it (`#| export`/`exporti`/`exportd`/`default_exp`) —
  `#| exports` keeps it, in a collapsible Quarto code-fold;
- the cell's *computed value* (not printed stdout/stderr — see the module
  docstring for why that's not captured yet) is embedded if it isn't
  `nothing`: spliced directly if it's a `Markdown.MD` (e.g. an explicit
  `show_doc(...)` call), otherwise as a fenced "text/plain" block;
- newly-exported public names not already explicitly `show_doc`'d get an
  auto-inserted `show_doc` card right after (nbdev's `add_show_docs`).

A cell whose evaluation errors gets a Quarto callout block noting the
error, and rendering continues with the next cell (unlike `test_nb`,
where any error stops everything — a docs render should still produce
*something* for cells later in the notebook).
"""
function render_notebook(
    nbpath::AbstractString,
    cfg::Config.NBConfig;
    index::Dict{String,SymbolEntry} = build_symbol_index(cfg),
    default_eval::Bool = true,
    skip_flags::AbstractSet{String} = Set(["notest"]),
    force_flags::AbstractSet{String} = Set{String}(),
)
    nb = NbIO.read_nb(nbpath)
    already = explicitly_shown_names(nb)
    mod = Module(Symbol("NBDevDocs_", replace(basename(nbpath), r"[^A-Za-z0-9]" => "_")))
    parts = String[]
    for cell in nb["cells"]
        ctype = get(cell, "cell_type", "")
        src = NbIO.cell_source(cell)
        src === nothing && continue

        if ctype == "markdown"
            haskey(NbIO.cell_directives(cell), "hide") || push!(parts, strip(src))
            continue
        end
        ctype == "code" || continue

        plan = plan_cell(cell, already)
        body_code = strip(NbIO.strip_directive_lines(src))
        exprs = toplevel_exprs(body_code)
        silent = !isempty(exprs) && is_silent_definition(last(exprs))

        value, errtext = nothing, nothing
        if does_cell_eval(cell, default_eval, skip_flags, force_flags)
            try
                value = Core.eval(mod, Meta.parseall(src))
            catch e
                errtext = sprint(showerror, e)
            end
        end

        if plan.visible
            if plan.show_source && !isempty(body_code)
                if plan.fold
                    push!(parts, "```{.julia}\n#| code-fold: show\n#| code-summary: \"Exported source\"\n$(body_code)\n```")
                else
                    push!(parts, "```julia\n$(body_code)\n```")
                end
            end
            if errtext !== nothing
                push!(parts, "::: {.callout-warning}\nError evaluating cell: $(errtext)\n:::")
            elseif value !== nothing && !silent
                # `value` was just produced by a fresh `Core.eval` above; operating on it
                # (show/string dispatch) from this already-compiled function needs
                # `invokelatest` or it's a world-age error waiting to happen — confirmed
                # empirically, not assumed (see progress_info.md).
                rendered = Base.invokelatest() do
                    value isa Markdown.MD ? string(value) : "```\n" * sprint(show, MIME"text/plain"(), value) * "\n```"
                end
                push!(parts, rendered)
            end
        end
        for nm in plan.auto_names
            push!(parts, string(show_doc(nm; mod = mod, index = index)))
        end
    end
    return join(parts, "\n\n") * "\n"
end

end # module NbDocs
