"""
Sync: the reverse direction of export — edits made directly in a generated
`.jl` library file get matched back to the originating notebook cell (by
the `#<cellid>` in `Export.jl`'s own provenance header, `# %% <relnb>
#<id>`) and written back into the notebook. The Julia analog of nbdev's
`sync.py` (`nbdev_update`).

Mechanically simpler than nbdev's version: nbdev has to re-discover
function/class boundaries inside the `.py` file to know what to match back
(Python cells can interleave in less structured ways), whereas every
nbdev cell already becomes its own contiguous, clearly-delimited
provenance block when exported (see `Export.write_module`), so syncing is
just "parse blocks back out by their header line, compare, splice."

Known, documented simplification vs. nbdev (same spirit as `Export.jl`'s
and `NbClean.jl`'s own documented simplifications): this is one-directional
and trusts the `.jl` file as the authority for whatever differs — it does
not detect or warn about the case where the *notebook* cell was also
edited independently since the last export (a true three-way conflict
between "last exported", "current notebook", and "current `.jl` file").
Running `export_project()` right before `sync_project()` minimizes the
risk (there's nothing to clobber if the notebook and the `.jl` file were
in sync a moment ago), but isn't enforced.
"""
module NbSync

export sync_project

using ..NbIO
using ..Config

"""
Every `(relnb, cellid, body)` provenance block in a generated file's text,
in order, split on `Export.jl`'s own header line (`# %% <relnb> #<id>`).
`body` is stripped of leading/trailing blank lines (matching the `strip`
`Export.write_module` already applies before writing it).
"""
function parse_provenance_blocks(filetext::AbstractString)
    # The id is matched as any non-whitespace token, not just hex: cell ids
    # are opaque strings, and `NbClean.clean_notebook`'s default
    # `clean_ids=true` renumbers them to `cell-<n>` (confirmed by 4
    # independent stress-test agents: a hex-only pattern here makes
    # `sync_project` silently never match anything — and therefore never
    # sync — for any project using the default config).
    header_re = r"^# %% (.+) #(\S*)$"
    blocks = Tuple{String,String,Vector{SubString{String}}}[]
    cur = nothing
    for line in split(filetext, '\n')
        m = match(header_re, line)
        if m !== nothing
            cur === nothing || push!(blocks, cur)
            cur = (String(m.captures[1]), String(m.captures[2]), SubString{String}[])
        elseif cur !== nothing
            push!(cur[3], line)
        end
    end
    cur === nothing || push!(blocks, cur)
    return [(relnb, id, strip(join(body, "\n"))) for (relnb, id, body) in blocks]
end

"""
Re-attach `new_body` after whatever real directive comment lines (`#|
...`) prefixed `src` originally — the part `Export.strip_directive_lines`
removed before writing to the `.jl` file, so it's the part that must be
reconstructed rather than round-tripped. Cell magics and blank lines in
the old leading block are deliberately *not* preserved verbatim (an
accepted simplification: genuinely rare in Julia notebooks, and nothing
is lost — a magic line that was present is still inside `new_body` as
written by `Export.write_module`, just no longer special-cased as
"leading").
"""
function splice_new_body(src::AbstractString, new_body::AbstractString)
    leading, _ = NbIO.partition_source(src)
    dirs = filter(l -> occursin(NbIO.DIR_PRE, l), leading)
    isempty(dirs) && return new_body
    return join(dirs) * new_body
end

"""
    sync_project(; cfg = Config.load_config())

Scan every `.jl` file under `cfg.src_path` for provenance blocks, and for
each one whose body differs from what its originating notebook cell
currently holds, splice the new body back into that cell (directive
comment lines preserved, see `splice_new_body`) and write the notebook.
Cells that no longer exist (deleted from the notebook since the last
export) or notebooks that no longer exist (moved/deleted) are silently
skipped — sync only ever updates an existing, matched cell, never creates
one. Returns `(; updated)`, a `Vector{Tuple{String,String}}` of
`(notebook_path, cell_id)` pairs that were actually changed.
"""
function sync_project(; cfg::Config.NBConfig = Config.load_config())
    updated = Tuple{String,String}[]
    nb_cache = Dict{String,Any}()
    isdir(cfg.d["src_path"]) || return (; updated)
    for (dir, _, files) in walkdir(cfg.d["src_path"])
        for f in files
            endswith(f, ".jl") || continue
            fname = joinpath(dir, f)
            blocks = parse_provenance_blocks(read(fname, String))
            isempty(blocks) && continue
            for (relnb, id, body) in blocks
                nbpath = normpath(joinpath(dir, relnb))
                isfile(nbpath) || continue
                nb = get!(() -> NbIO.read_nb(nbpath), nb_cache, nbpath)
                idx = findfirst(c -> get(c, "id", "") == id, nb["cells"])
                idx === nothing && continue
                cell = nb["cells"][idx]
                src = NbIO.cell_source(cell)
                src === nothing && continue
                strip(NbIO.strip_directive_lines(src)) == body && continue
                NbIO.set_cell_source!(cell, splice_new_body(src, body))
                push!(updated, (nbpath, id))
            end
        end
    end
    for (nbpath, _) in unique(first, updated)
        NbIO.write_nb(nb_cache[nbpath], nbpath)
    end
    return (; updated)
end

end # module NbSync
