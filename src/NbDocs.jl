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
"""
module NbDocs

export SymbolEntry, build_symbol_index, show_doc

using Markdown

using ..Config
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
`Dict{String,SymbolEntry}` mapping each name nbjulia-exported code
defines to where it came from. Last writer wins if (unusually) the same
name is defined in two places. Not a full equivalent of nbdev's
cross-package `_modidx.py` lookup (no `entry_points`-based lookup across
other installed nbjulia packages) — just this project's own symbols, for
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
one nbjulia exported — the Julia analog of nbdev's source-link.
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
        Core.eval(lookupmod, Meta.parse("@doc " * nm))
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

end # module NbDocs
