"""
Git integration: clean-filter/merge/diff driver registration, and the
merge/diff drivers themselves. The Julia analog of nbdev's `merge.py` +
`diff.py` + the hook-installation part of `clean.py`/`cli.py`.

As `ARCHITECTURE.md` notes, this is the least language-dependent subsystem
of the whole project — it's mostly git-config plumbing and text/JSON
manipulation, so it translates close to 1:1 from nbdev's own design:

- **Merge driver**: try ordinary `git merge-file` first (empirically
  verified this session: it succeeds more often than "fully overlapping
  edits only" would suggest, but conflicts surprisingly easily even on
  *adjacent*, non-overlapping line changes — so this is a real fast path,
  not a formality, but the JSON fallback below is what actually carries the
  feature). If that still leaves conflict markers, fall back to aligning
  the three notebook variants (base/ours/theirs) by cell `id` and merging
  cell-by-cell: a cell changed on only one side is taken automatically; a
  cell changed differently on both sides becomes *two* adjacent cells in
  the output, each wrapped in a labeled markdown separator, so a human
  resolves it by deleting the one they don't want — in the Jupyter UI,
  never by hand-editing conflict markers in raw JSON.
- **Diff driver**: same cell-by-id alignment, but only used to flatten each
  side to a cell-source-only text view (outputs ignored, same as nbdev),
  which is then handed to the system `diff -u` so `git diff`/`git log -p`
  on a notebook reads like a diff of source code.

Both git driver protocols (argument order for `merge.<x>.driver`'s `%O %A
%B %P` and `diff.<x>.command`'s 7 trailing positional args) were verified
empirically against the real installed `git` (2.53.0) before relying on
them, not assumed from memory.
"""
module NbGit

export install_hooks, merge_driver_main, diff_driver_main

using ..NbIO
using ..Config
using JSON
using OrderedCollections

# ---------------------------------------------------------------------------
# Hook installation
# ---------------------------------------------------------------------------

"POSIX-shell-quote `s` (git re-invokes driver command strings via `sh -c`, so values stored in git config must be valid shell words even though this function's own `run(` ``git config key val` ``)` call needs no quoting of its own — Julia's backtick commands exec argv directly, no shell involved)."
shell_quote(s::AbstractString) = "'" * replace(s, "'" => raw"'\''") * "'"

"The `julia --project=<root> -e '<call>'` command line one of nbjulia's drivers runs as."
julia_driver_cmd(cfg::Config.NBConfig, call::AbstractString) =
    "julia --project=$(shell_quote(cfg.root)) -e $(shell_quote("using NBJulia; " * call))"

const ATTR_LINES = (
    "*.ipynb filter=nbjulia-clean",
    "*.ipynb merge=nbjulia-notebook",
    "*.ipynb diff=nbjulia-notebook",
)

"""
    install_hooks(; cfg = Config.load_config())

Register nbjulia's clean filter and merge/diff drivers for `*.ipynb` files
in this project's git repo: appends the attribute lines in `ATTR_LINES` to
`.gitattributes` (creating it if needed; only the lines not already
present are added), and sets the matching `filter.*`/`merge.*`/`diff.*`
entries in the **repo-local** git config (`git -C cfg.root config ...` —
never touches global config, never requires a GitHub remote). Idempotent:
safe to call again, e.g. after moving the project to a new path.
"""
function install_hooks(; cfg::Config.NBConfig = Config.load_config())
    isdir(joinpath(cfg.root, ".git")) ||
        error("install_hooks: $(cfg.root) is not a git repository root (no .git directory found).")

    attrpath = joinpath(cfg.root, ".gitattributes")
    existing = isfile(attrpath) ? readlines(attrpath) : String[]
    to_add = [l for l in ATTR_LINES if !(l in existing)]
    if !isempty(to_add)
        open(attrpath, "a") do io
            for l in to_add
                println(io, l)
            end
        end
    end

    setcfg(key, val) = run(`git -C $(cfg.root) config $key $val`)
    setcfg("filter.nbjulia-clean.clean", julia_driver_cmd(cfg, "NBJulia.clean_filter_main()"))
    setcfg("filter.nbjulia-clean.smudge", "cat")
    setcfg("filter.nbjulia-clean.required", "false")
    setcfg("merge.nbjulia-notebook.name", "nbjulia notebook merge driver")
    setcfg(
        "merge.nbjulia-notebook.driver",
        julia_driver_cmd(cfg, "exit(NBJulia.merge_driver_main(ARGS))") * " -- %O %A %B %P",
    )
    setcfg("diff.nbjulia-notebook.command", julia_driver_cmd(cfg, "NBJulia.diff_driver_main(ARGS)"))
    return nothing
end

# ---------------------------------------------------------------------------
# Shared: parse a possibly-invalid-JSON blob into a notebook dict, or `nothing`
# ---------------------------------------------------------------------------

function try_parse_nb(txt::AbstractString)
    try
        nb = JSON.parse(txt; dicttype = OrderedDict{String,Any})
        haskey(nb, "cells") || return nothing
        for cell in nb["cells"]
            haskey(cell, "source") && (cell["source"] = NbIO.cell_source(cell))
            haskey(cell, "id") || (cell["id"] = NbIO.new_cell_id())
        end
        return nb
    catch
        return nothing
    end
end

# ---------------------------------------------------------------------------
# Merge driver
# ---------------------------------------------------------------------------

"`id => cell` for every cell in `nb` (last one wins on a duplicate id, which shouldn't happen in practice)."
function cell_map(nb)
    d = OrderedDict{String,Any}()
    for c in get(nb, "cells", Any[])
        d[get(c, "id", "")] = c
    end
    return d
end

"Two cells are the same edit for merge purposes if their type and source text match (metadata/outputs differences don't count as a conflict)."
same_cell(a, b) = get(a, "cell_type", "") == get(b, "cell_type", "") && NbIO.cell_source(a) == NbIO.cell_source(b)

"""
    merge_cells(base, ours, theirs)

Three-way merge of notebooks `base`/`ours`/`theirs`, aligned by cell `id`.
Returns `(merged_nb, had_conflict::Bool)`. See the module docstring for the
policy (auto-take a one-sided change, surface a true conflict as two
labeled adjacent cells).
"""
function merge_cells(base, ours, theirs)
    base_m, ours_m, theirs_m = cell_map(base), cell_map(ours), cell_map(theirs)
    ours_order = [get(c, "id", "") for c in get(ours, "cells", Any[])]
    theirs_order = [get(c, "id", "") for c in get(theirs, "cells", Any[])]
    ordered_ids = vcat(ours_order, [id for id in theirs_order if !(id in ours_order)])

    merged_cells = Any[]
    had_conflict = false
    mark(label) = push!(merged_cells, NbIO.markdown_cell("--- nbjulia merge conflict: $(label) ---"))

    for id in ordered_ids
        in_base, in_ours, in_theirs = haskey(base_m, id), haskey(ours_m, id), haskey(theirs_m, id)
        if in_ours && in_theirs
            o, t = ours_m[id], theirs_m[id]
            if same_cell(o, t) || (in_base && same_cell(base_m[id], t))
                push!(merged_cells, o) # unchanged, or only theirs matched base -> ours wins trivially
            elseif in_base && same_cell(base_m[id], o)
                push!(merged_cells, t) # only theirs changed it
            else
                had_conflict = true
                mark("OURS ↓")
                # `o` and `t` share `id` whenever `clean_ids` normalized both
                # sides to the same position-based id before they diverged —
                # give each inserted alternative a fresh id so the merged
                # notebook never has two cells with the same id (confirmed by
                # 3 independent stress-test agents: that duplicate breaks the
                # id-uniqueness invariant `sync_project`/`build_symbol_index`
                # rely on, and can cause an id-keyed script to touch both
                # conflicting cells at once instead of one).
                o2 = deepcopy(o)
                o2["id"] = NbIO.new_cell_id()
                push!(merged_cells, o2)
                mark("THEIRS ↓")
                t2 = deepcopy(t)
                t2["id"] = NbIO.new_cell_id()
                push!(merged_cells, t2)
                mark("delete whichever side you don't want ↑")
            end
        elseif in_ours && !in_theirs
            o = ours_m[id]
            if in_base && !same_cell(base_m[id], o)
                had_conflict = true
                mark("OURS edited, THEIRS deleted")
                push!(merged_cells, o)
            elseif !in_base
                push!(merged_cells, o) # ours added a new cell
            end
            # else: ours left it unchanged and theirs cleanly deleted it -> drop.
        elseif !in_ours && in_theirs
            t = theirs_m[id]
            if in_base && !same_cell(base_m[id], t)
                had_conflict = true
                mark("THEIRS edited, OURS deleted")
                push!(merged_cells, t)
            elseif !in_base
                push!(merged_cells, t) # theirs added a new cell
            end
            # else: theirs left it unchanged and ours cleanly deleted it -> drop.
        end
    end

    merged = deepcopy(ours)
    merged["cells"] = merged_cells
    return merged, had_conflict
end

"""
    merge_driver_main(args)

Entry point for the git `merge` driver. `args` is `[ancestor, ours, theirs,
path]` — the `%O %A %B %P` git substitutes into
`merge.nbjulia-notebook.driver` (verified empirically: `%A`'s file already
holds "ours" content when the driver is invoked, and the driver is
expected to overwrite `%A` in place with the merge result). Returns `0` on
a clean merge, `1` if a true conflict remains (so git still reports the
merge as conflicted) — the caller (the tiny `-e` script `install_hooks`
registers) turns this into the process exit code via `exit(...)`.
"""
function merge_driver_main(args::Vector{String})
    length(args) >= 4 ||
        error("merge_driver_main: expected 4 args (ancestor ours theirs path), got $(length(args))")
    O, A, B, P = args[1], args[2], args[3], args[4]
    base_txt, ours_txt, theirs_txt = read(O, String), read(A, String), read(B, String)

    tmp_a = tempname()
    write(tmp_a, ours_txt)
    status = run(ignorestatus(`git merge-file -q $tmp_a $O $B`))
    if status.exitcode == 0
        cp(tmp_a, A; force = true)
        rm(tmp_a; force = true)
        return 0
    end
    rm(tmp_a; force = true)

    base_nb, ours_nb, theirs_nb = try_parse_nb(base_txt), try_parse_nb(ours_txt), try_parse_nb(theirs_txt)
    if base_nb === nothing || ours_nb === nothing || theirs_nb === nothing
        write(A, "<<<<<<< ours\n$(ours_txt)\n=======\n$(theirs_txt)\n>>>>>>> theirs ($(P))\n")
        return 1
    end

    merged, had_conflict = merge_cells(base_nb, ours_nb, theirs_nb)
    NbIO.write_nb(merged, A)
    return had_conflict ? 1 : 0
end

# ---------------------------------------------------------------------------
# Diff driver
# ---------------------------------------------------------------------------

"Flattened, outputs-ignored text view of the notebook at `path` (one block per cell, in order) — the actual thing diffed, so a notebook diff reads like a diff of source code, not raw JSON. `path == \"/dev/null\"` (added/deleted file) yields an empty string."
function flatten_nb(path::AbstractString)
    path == "/dev/null" && return ""
    txt = read(path, String)
    nb = try_parse_nb(txt)
    nb === nothing && return txt # not parseable notebook JSON -> diff the raw bytes instead
    parts = String[]
    for cell in get(nb, "cells", Any[])
        src = NbIO.cell_source(cell)
        src === nothing && continue
        push!(parts, "# %% [$(get(cell, "cell_type", "?"))] $(get(cell, "id", ""))\n" * rstrip(src) * "\n")
    end
    return join(parts, "\n")
end

"""
    diff_driver_main(args)

Entry point for the git `diff` driver. `args` is `[path, old_file,
old_hex, old_mode, new_file, new_hex, new_mode]` — the 7 positional
arguments git appends automatically after `diff.nbjulia-notebook.command`
(verified empirically against real `git diff`; no `%`-token substitution
needed for a diff driver, unlike a merge driver). Prints a unified diff of
each side's flattened cell-source text to stdout.
"""
function diff_driver_main(args::Vector{String})
    length(args) >= 5 ||
        error("diff_driver_main: expected at least 5 args (path old-file ... new-file ...), got $(length(args))")
    path, old_file, new_file = args[1], args[2], args[5]
    old_tmp, new_tmp = tempname(), tempname()
    write(old_tmp, flatten_nb(old_file))
    write(new_tmp, flatten_nb(new_file))
    run(ignorestatus(`diff -u --label a/$(path) --label b/$(path) $old_tmp $new_tmp`))
    rm(old_tmp; force = true)
    rm(new_tmp; force = true)
    return 0
end

end # module NbGit
