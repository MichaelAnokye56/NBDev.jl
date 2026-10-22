"""
Clean: strip the noisy, non-semantic parts of a notebook's JSON so two
people editing different cells don't produce a line-level git conflict
across the entire blob. The Julia analog of nbdev's `clean.py`.

Mirrors nbdev's documented behavior: null out `execution_count`, drop most
cell/notebook metadata keys (keeping only `kernelspec`/`jupyter`/`widgets`/
`nbdev` — `nbdev` is kept deliberately, since `NbIO.cell_directives` reads
directives out of `metadata.nbdev` as a fallback to comment directives),
and either clear every output (`clear_all=true`) or keep outputs with
address-repr noise stripped (`clear_all=false`, the default — nbdev's own
default too).

Known, documented simplification vs. real nbdev: `clean_ids=true` (the
default) replaces every cell's `id` with a short deterministic `"cell-<n>"`
derived from its position, rather than leaving whatever id Jupyter assigned.
Real Jupyter sometimes assigns a *new* random id to an otherwise-unchanged
cell on every save — exactly the spurious diff noise `clean` exists to
remove — so two collaborators who both run `clean` end up with
byte-identical ids for equivalent cells regardless of whichever random id
their own Jupyter session happened to pick. Set `clean_ids=false` to leave
existing ids untouched (only a cell genuinely missing one gets a fresh
random id, same as `NbIO.read_nb`).
"""
module NbClean

export clean_notebook, clean_nb, clean_project, clean_filter_main

using ..NbIO
using ..Config
using JSON
using OrderedCollections

const NB_META_KEEP = ("kernelspec", "jupyter", "widgets", "nbdev")
const ADDR_RE = r"0x[0-9a-fA-F]{4,}"

"Strip hex-address repr noise (e.g. `Ptr{Nothing} @0x00007f1234`) from `s`."
strip_addr_noise(s::AbstractString) = replace(s, ADDR_RE => "0x...")
strip_addr_noise(v::AbstractVector) = [strip_addr_noise(x) for x in v]
strip_addr_noise(x) = x

"Clean one output dict in place: null its own `execution_count`, strip address noise from its text payloads."
function clean_output!(out::AbstractDict)
    haskey(out, "execution_count") && (out["execution_count"] = nothing)
    haskey(out, "text") && (out["text"] = strip_addr_noise(out["text"]))
    if haskey(out, "data") && out["data"] isa AbstractDict
        data = out["data"]
        haskey(data, "text/plain") && (data["text/plain"] = strip_addr_noise(data["text/plain"]))
    end
    return out
end

"`meta` filtered down to only the keys in `keep`, preserving insertion order."
function filter_metadata(meta, keep)
    od = OrderedDict{String,Any}()
    for (k, v) in meta
        String(k) in keep && (od[String(k)] = v)
    end
    return od
end

"""
    clean_notebook(nb; clear_all=false, clean_ids=true)

Return a cleaned copy of notebook `nb` (does not mutate `nb`). See the
module docstring for exactly what's stripped and why.
"""
function clean_notebook(nb; clear_all::Bool = false, clean_ids::Bool = true)
    out = deepcopy(nb)
    haskey(out, "metadata") && (out["metadata"] = filter_metadata(out["metadata"], NB_META_KEEP))
    cells = get(out, "cells", Any[])
    for (i, cell) in enumerate(cells)
        haskey(cell, "metadata") && (cell["metadata"] = filter_metadata(cell["metadata"], NB_META_KEEP))
        if get(cell, "cell_type", "") == "code"
            cell["execution_count"] = nothing # a code cell always carries this key per nbformat, even when null
            if clear_all
                cell["outputs"] = Any[]
            else
                for o in get(cell, "outputs", Any[])
                    o isa AbstractDict && clean_output!(o)
                end
            end
        end
        if clean_ids
            cell["id"] = "cell-$(i - 1)"
        elseif !haskey(cell, "id")
            cell["id"] = NbIO.new_cell_id()
        end
    end
    return out
end

"""
    clean_nb(path; clear_all=false, clean_ids=true)

Clean the notebook at `path` in place. No-op on disk (via `NbIO.write_nb`'s
own change-detection) if the cleaned form is already byte-identical to
what's there — so running `clean` repeatedly, e.g. from a pre-commit hook,
never touches mtimes or git status on an already-clean file.
"""
function clean_nb(path::AbstractString; clear_all::Bool = false, clean_ids::Bool = true)
    nb = NbIO.read_nb(path)
    NbIO.write_nb(clean_notebook(nb; clear_all, clean_ids), path)
    return nothing
end

"""
    clean_project(; cfg = Config.load_config())

Clean every notebook under `cfg.nbs_path`, using `cfg`'s own `clear_all`/
`clean_ids` settings.
"""
function clean_project(; cfg::Config.NBConfig = Config.load_config())
    for nbpath in Config.find_notebooks(cfg)
        clean_nb(nbpath; clear_all = cfg.d["clear_all"], clean_ids = cfg.d["clean_ids"])
    end
    return nothing
end

"""
    clean_filter_main(; io_in=stdin, io_out=stdout)

Entry point for the git `clean` filter driver (registered by
`NbGit.install_hooks` as `filter.nbdev-clean.clean`): reads one
notebook's JSON straight from `io_in` (git pipes the blob's content on
stdin — there is no reliable file path to work from), cleans it, writes
the result to `io_out`. Falls back to `Config.load_config()`'s defaults
(`clear_all=false`, `clean_ids=true`) if no `Project.toml` can be found
from the current directory (git always runs filter drivers with `cwd` set
to the repo root, but a bare/fresh clone might not have one yet).
"""
function clean_filter_main(; io_in::IO = stdin, io_out::IO = stdout)
    nb = JSON.parse(read(io_in, String); dicttype = OrderedDict{String,Any})
    for cell in get(nb, "cells", Any[])
        haskey(cell, "source") && (cell["source"] = NbIO.cell_source(cell))
    end
    clear_all, clean_ids = try
        cfg = Config.load_config()
        cfg.d["clear_all"], cfg.d["clean_ids"]
    catch
        false, true
    end
    cleaned = clean_notebook(nb; clear_all, clean_ids)
    print(io_out, NbIO.nb2str(cleaned))
    return nothing
end

end # module NbClean
