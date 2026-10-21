"""
Notebook JSON I/O, cell helpers, and directive parsing. The Julia analog of
nbdev's `fastcore.nbio` (read_nb/write_nb/NbCell/.directives).

A notebook is kept as a plain `OrderedDict{String,Any}` (what `JSON.parsefile`
returns with `dicttype=OrderedDict{String,Any}`) and a cell is a plain
`OrderedDict{String,Any}` nested inside its `"cells"` vector — there is no
separate wrapper type. This mirrors nbdev's own choice (`NbCell` is just an
`AttrDict`, i.e. a dict with dot-access) rather than introducing a rigid
struct that would make round-tripping unknown nbformat keys fragile.

Directive comment syntax (`#| export`, `#| default_exp core`, `#| hide`, ...)
is unchanged from nbdev — Julia's comment character is also `#`, so nbdev's
own regex-level directive grammar applies unmodified.
"""
module NbIO

export read_nb, write_nb, nb2str, nb_lang, cell_source, set_cell_source!,
       partition_source, cell_directives, has_directive, get_directive,
       remove_directives!, strip_directive_lines, new_cell_id,
       code_cell, markdown_cell, new_notebook

using JSON
using OrderedCollections

# ---------------------------------------------------------------------------
# Directive grammar (same as nbdev's `_dir_pre`/`_directive`/`_meta_directives`)
# ---------------------------------------------------------------------------

const DIR_PRE = r"^\s*#\s*\|"
const MAGIC_RE = r"^\s*%%\w+"
const BLANK_RE = r"^\s*$"

"Parse one directive comment line into `name => value` (`\"\"` for bare), or `nothing`."
function parse_directive(line::AbstractString)
    occursin(DIR_PRE, line) || return nothing
    rest = strip(replace(line, DIR_PRE => "", count = 1))
    m = match(r"^([^\s:]+)\s*:?\s?(.*?)\s*$", rest)
    m === nothing && return nothing
    name, v = m.captures[1], m.captures[2]
    return String(name) => (v == "true" ? "" : String(v))
end

"Directives stored in a cell/notebook's `metadata.nbdev` dict, as `{name => value}`."
function meta_directives(metadata)
    d = get(metadata, "nbdev", OrderedDict{String,Any}())
    return Dict{String,String}(String(k) => (string(v) == "true" ? "" : string(v)) for (k, v) in d)
end

"Split lines, keeping line endings attached (like Python's `str.splitlines(keepends=True)`)."
function splitlines_keepends(s::AbstractString)
    isempty(s) && return String[]
    lines = String[]
    buf = IOBuffer()
    for c in s
        print(buf, c)
        c == '\n' && (push!(lines, String(take!(buf))))
    end
    rest = String(take!(buf))
    isempty(rest) || push!(lines, rest)
    return lines
end

"""
    partition_source(src)

Split `src` into `(leading, rest)`: the leading run of directive-comment /
cell-magic / blank lines, and everything after. Mirrors nbdev's
`NbCell._partition`.
"""
function partition_source(src::AbstractString)
    lines = splitlines_keepends(src)
    n = 0
    for l in lines
        (occursin(DIR_PRE, l) || occursin(MAGIC_RE, l) || occursin(BLANK_RE, l)) || break
        n += 1
    end
    return lines[1:n], lines[(n + 1):end]
end

# ---------------------------------------------------------------------------
# Cell accessors
# ---------------------------------------------------------------------------

"""
Cell source as a single `String`, `nothing` if the cell has been hidden
(source explicitly set to `nothing` by a processor — nbdev's `del(cell['source'])`).
nbformat allows source as either a string or a list of lines; either is joined.
"""
function cell_source(cell)
    s = get(cell, "source", "")
    s === nothing && return nothing
    return s isa AbstractVector ? join(s) : s
end

function set_cell_source!(cell, text)
    cell["source"] = text
    return cell
end

"Merged directives for `cell`: comment directives win over `metadata.nbdev` directives."
function cell_directives(cell)
    src = cell_source(cell)
    src === nothing && return Dict{String,String}()
    dirs, _ = partition_source(src)
    cmts = Dict{String,String}()
    for l in dirs
        d = parse_directive(l)
        d === nothing || (cmts[d.first] = d.second)
    end
    merged = meta_directives(get(cell, "metadata", OrderedDict{String,Any}()))
    merge!(merged, cmts)
    return merged
end

has_directive(cell, name::AbstractString) = haskey(cell_directives(cell), name)
get_directive(cell, name::AbstractString, default = nothing) = get(cell_directives(cell), name, default)

"Pure version of `remove_directives!`: directive comment lines stripped, cell magics kept."
function strip_directive_lines(src::AbstractString)
    dirs, code = partition_source(src)
    keep = filter(l -> occursin(MAGIC_RE, l), dirs)
    return join(vcat(keep, code))
end

"Strip directive comment lines from `cell`'s source in place, keeping cell magics."
function remove_directives!(cell)
    src = cell_source(cell)
    src === nothing && return cell
    set_cell_source!(cell, strip_directive_lines(src))
    return cell
end

# ---------------------------------------------------------------------------
# Notebook-level helpers
# ---------------------------------------------------------------------------

function nb_lang(nb)
    meta = get(nb, "metadata", OrderedDict{String,Any}())
    ks = get(meta, "kernelspec", OrderedDict{String,Any}())
    return get(ks, "language", "julia")
end

const HEX = "0123456789abcdef"
new_cell_id(n::Int = 4) = String([HEX[rand(1:16)] for _ in 1:(2n)])

# ---------------------------------------------------------------------------
# Read / write
# ---------------------------------------------------------------------------

"""
    read_nb(path)

Read a `.ipynb` file into a plain `OrderedDict{String,Any}`. Every cell's
`source` is normalized to a single `String`, and any cell missing an `id`
(pre-4.5 notebooks) gets one generated.
"""
function read_nb(path::AbstractString)
    nb = JSON.parsefile(path; dicttype = OrderedDict{String,Any})
    for cell in nb["cells"]
        haskey(cell, "source") && (cell["source"] = cell_source(cell))
        haskey(cell, "id") || (cell["id"] = new_cell_id())
    end
    return nb
end

sort_keys_recursive(x::AbstractDict) = begin
    od = OrderedDict{String,Any}()
    for k in sort(collect(String.(keys(x))))
        od[k] = sort_keys_recursive(x[k])
    end
    od
end
sort_keys_recursive(x::AbstractVector) = [sort_keys_recursive(v) for v in x]
sort_keys_recursive(x) = x

"Canonical serialized form of `nb`: keys sorted recursively (clean git diffs), 1-space indent."
nb2str(nb) = JSON.json(sort_keys_recursive(nb), 1) * "\n"

"""
    write_nb(nb, path)

Write `nb` to `path`, only touching the file if the serialized form
actually changed (keeps mtimes/git status quiet on no-op runs).
"""
function write_nb(nb, path::AbstractString)
    new_text = nb2str(nb)
    old_text = isfile(path) ? read(path, String) : nothing
    new_text == old_text && return nothing
    open(io -> write(io, new_text), path, "w")
    return nothing
end

# ---------------------------------------------------------------------------
# Building fresh notebooks (used by scaffolding, and handy for tests)
# ---------------------------------------------------------------------------

"A fresh code cell dict, structurally valid nbformat (so real Jupyter/VS Code can open it)."
function code_cell(source::AbstractString; id::String = new_cell_id())
    return OrderedDict{String,Any}(
        "cell_type" => "code",
        "execution_count" => nothing,
        "metadata" => OrderedDict{String,Any}(),
        "outputs" => Any[],
        "source" => source,
        "id" => id,
    )
end

"A fresh markdown cell dict."
function markdown_cell(source::AbstractString; id::String = new_cell_id())
    return OrderedDict{String,Any}(
        "cell_type" => "markdown",
        "metadata" => OrderedDict{String,Any}(),
        "source" => source,
        "id" => id,
    )
end

"""
    new_notebook(cells; display_name="Julia", kernel_name="julia-1.13", julia_version=string(VERSION))

A fresh notebook dict (nbformat 4.5) from a list of cells (`code_cell`/
`markdown_cell`), with a Julia kernelspec so `nb_lang` resolves to `"julia"`.
"""
function new_notebook(
    cells::AbstractVector;
    display_name::AbstractString = "Julia",
    kernel_name::AbstractString = "julia-1.13",
    julia_version::AbstractString = string(VERSION),
)
    return OrderedDict{String,Any}(
        "cells" => Any[cells...],
        "metadata" => OrderedDict{String,Any}(
            "kernelspec" => OrderedDict{String,Any}(
                "display_name" => display_name, "language" => "julia", "name" => kernel_name,
            ),
            "language_info" => OrderedDict{String,Any}(
                "file_extension" => ".jl", "mimetype" => "application/julia",
                "name" => "julia", "version" => julia_version,
            ),
        ),
        "nbformat" => 4,
        "nbformat_minor" => 5,
    )
end

end # module NbIO
