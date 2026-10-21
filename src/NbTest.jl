"""
Run notebooks as tests: the Julia analog of nbdev's `test.py`
(`nb_test_cells`/`test_nb`/`nbdev_test`).

A notebook's code cells *are* the tests — the same philosophy as nbdev:
re-execute the notebook top to bottom, in document order, and any cell
raising an exception is a failure. There's no separate assertion DSL to
learn: a bare `@assert cond` needs no import at all, and `using Test` +
`@test`/`@testset` work exactly as they would in a script (confirmed: a
failing bare `@test` throws `Test.FallbackTestSetException`, a passing one
is silent — no special integration needed).

Unlike nbdev, which needs `execnb` (an in-process IPython-shell
reimplementation) to get this without real Jupyter-kernel overhead, Julia
gets the same thing directly: `Core.eval` a fresh `Module` per notebook,
one cell (via `Meta.parseall`, so a multi-statement cell is one coherent
top-level block) at a time. No shell reimplementation needed, and (verified
empirically) no world-age problem either — each `Core.eval` call inside the
loop sees methods defined by earlier iterations of the same loop.

Directive comment lines are *not* stripped before execution (matching
nbdev's own `test_nb`, which reads with `rm_directives=False`) — they're
inert Julia comments at runtime, so there's nothing to strip for; only the
*export* path needs clean source.

Known simplification vs. nbdev: no notebook-level frontmatter `eval`
override yet (`fm_default_eval` — needs Phase 3's frontmatter parsing), no
per-cell timeout enforcement, and notebooks run serially, not in a process
pool. All revisit-worthy once more of the pipeline exists.
"""
module NbTest

export test_nb, test_project, select_test_cells, does_cell_eval

using ..NbIO
using ..Config

# ---------------------------------------------------------------------------
# Eval-participation cascade (nbdev's does_cell_eval + test.py's skip_flags)
# ---------------------------------------------------------------------------

"""
    does_cell_eval(cell, default, skip_flags, force_flags)

Does `cell` participate in a non-interactive run? A non-code cell never
does. Its own `#| eval` directive (if present) decides outright (bare/
`true` → yes, `false` → no). Otherwise, if any of its directives are in
`skip_flags` (and not also in `force_flags`, which cancels a skip flag
out), it's skipped — this is what makes `#| notest` cells skipped by
default. Otherwise falls back to `default`.
"""
function does_cell_eval(
    cell,
    default::Bool,
    skip_flags::AbstractSet{String} = Set{String}(),
    force_flags::AbstractSet{String} = Set{String}(),
)
    get(cell, "cell_type", "") == "code" || return false
    dirs = NbIO.cell_directives(cell)
    ev = get(dirs, "eval", nothing)
    if ev !== nothing
        lv = lowercase(ev)
        lv in ("", "true") && return true
        lv == "false" && return false
    end
    active_skips = setdiff(skip_flags, force_flags)
    if !isempty(active_skips) && !isempty(intersect(active_skips, keys(dirs)))
        return false
    end
    return default
end

"""
    select_test_cells(nb; skip_flags=Set(["notest"]), force_flags=Set{String}(), default_eval=true)

The code cells of notebook `nb` (as returned by `NbIO.read_nb`) that
`test_nb` would run, in document order.
"""
function select_test_cells(
    nb;
    skip_flags::AbstractSet{String} = Set(["notest"]),
    force_flags::AbstractSet{String} = Set{String}(),
    default_eval::Bool = true,
)
    return [c for c in nb["cells"] if does_cell_eval(c, default_eval, skip_flags, force_flags)]
end

# ---------------------------------------------------------------------------
# Running one notebook
# ---------------------------------------------------------------------------

"Which cell of a notebook failed, and how."
struct CellError
    idx::Int            # position among the *selected* cells (1-based)
    id::String           # the cell's nbformat id
    error::Any
    backtrace::Any
end

function Base.showerror(io::IO, e::CellError)
    print(io, "cell $(e.idx) (id $(e.id)): ")
    showerror(io, e.error)
end

_sandbox_name(path::AbstractString) = Symbol("NBJuliaTest_" * replace(basename(path), r"[^A-Za-z0-9]" => "_") * "_" * string(objectid(path)))

"""
    test_nb(path; skip_flags=Set(["notest"]), force_flags=Set{String}())

Re-execute notebook `path`'s selected code cells, in document order, in a
fresh sandbox module. Cell output (`println`, `@info`, ...) streams to the
real stdout/stderr as cells run — there's no quiet-unless-failed capture
in this version (an `IOBuffer` isn't a valid `redirect_stdout` target in
Base Julia; that needs a `Pipe`, which brings back exactly the kind of
careful-plumbing-or-it-deadlocks territory this project has already hit
once this session — not worth it for a first cut. Revisit if the noise
becomes a real problem.).

Returns `(passed::Bool, elapsed::Float64, err::Union{Nothing,CellError})`.
"""
function test_nb(
    path::AbstractString;
    skip_flags::AbstractSet{String} = Set(["notest"]),
    force_flags::AbstractSet{String} = Set{String}(),
)
    nb = NbIO.read_nb(path)
    cells = select_test_cells(nb; skip_flags, force_flags)
    mod = Module(_sandbox_name(path))
    start = time()
    for (idx, cell) in enumerate(cells)
        src = NbIO.cell_source(cell)
        src === nothing && continue
        isempty(strip(src)) && continue
        try
            Core.eval(mod, Meta.parseall(src))
        catch e
            return false, time() - start, CellError(idx, get(cell, "id", "?"), e, catch_backtrace())
        end
    end
    return true, time() - start, nothing
end

# ---------------------------------------------------------------------------
# Running the whole project
# ---------------------------------------------------------------------------

"""
    test_project(; cfg=Config.load_config(), skip_flags=Set(["notest"]),
                 force_flags=Set{String}(), do_print=false)

Re-execute every notebook under `cfg.nbs_path` (see `test_nb`), serially,
printing a pass/fail summary (and, for any failure, the failing cell's
error). Returns `true` iff every notebook passed.
"""
function test_project(;
    cfg::Config.NBConfig = Config.load_config(),
    skip_flags::AbstractSet{String} = Set(["notest"]),
    force_flags::AbstractSet{String} = Set{String}(),
    do_print::Bool = false,
)
    files = Config.find_notebooks(cfg)
    if isempty(files)
        println("No notebooks found under $(cfg.d["nbs_path"])")
        return true
    end
    failures = Tuple{String,CellError}[]
    for f in files
        do_print && println("Starting $(f)")
        passed, elapsed, err = test_nb(f; skip_flags, force_flags)
        if passed
            do_print && println("- Completed $(f) ($(round(elapsed; digits = 2))s)")
        else
            push!(failures, (f, err))
            do_print && println("- FAILED $(f)")
        end
    end
    if isempty(failures)
        println("Success.")
        return true
    end
    println()
    println("="^50)
    println("nbjulia Tests Failed On The Following Notebooks:")
    for (f, err) in failures
        println("\t", f)
        println("\t\t", sprint(showerror, err))
    end
    return false
end

end # module NbTest
