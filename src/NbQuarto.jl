"""
Stage rendered notebooks into a Quarto project and shell out to `quarto
render` — the Julia analog of nbdev's `quarto.py` (`nbdev_docs`/
`_pre_docs`). Same division of labor as nbdev itself: nbdev prepares
plain, already-rendered content; Quarto turns it into an HTML site. The
`.qmd` files `render_notebook` (`NbDocs.jl`) produces already have every
cell's output baked in as text, so the staged Quarto project is built
with `execute: enabled: false` — Quarto's job here is pure markdown→HTML,
never re-running any code (confirmed empirically against the real
`quarto` binary: a fenced `` ```{.julia} `` chunk with `execute: enabled:
false` renders its code-fold/code-summary options correctly without
Quarto ever attempting to find or invoke a Julia execution engine).

Known simplification vs. nbdev: no `sidebar.yml` generation — delegated
to Quarto's own `sidebar: contents: auto`, which discovers pages from the
staged directory structure directly, since nbdev doesn't yet have
nbdev's doc_host/git_url config fields to build a fancier one from.
"""
module NbQuarto

export stage_docs, render_docs

using ..Config
using ..NbDocs: build_symbol_index, render_notebook

function quarto_yml(output_dir::AbstractString, title::AbstractString)
    return """
    project:
      type: website
      output-dir: $(output_dir)

    execute:
      enabled: false

    format:
      html:
        theme: cosmo
        toc: true

    website:
      title: "$(title)"
      sidebar:
        style: floating
        contents: auto
    """
end

"""
    stage_docs(cfg=Config.load_config(); index=build_symbol_index(cfg))

Render every notebook under `cfg.nbs_path` to a `.qmd` file in a staging
directory (`<cfg.root>/_proc`, wiped and recreated each call), mirroring
the notebooks' relative paths, and write a `_quarto.yml` there whose
`output-dir` points straight at `cfg.doc_path` (so `quarto render` writes
the finished site directly there — no separate move-into-place step
needed). Returns the staging directory path.
"""
function stage_docs(cfg::Config.NBConfig = Config.load_config(); index::Dict = build_symbol_index(cfg))
    stage = joinpath(cfg.root, "_proc")
    isdir(stage) && rm(stage; recursive = true)
    mkpath(stage)
    for nbpath in Config.find_notebooks(cfg)
        relnb = relpath(nbpath, cfg.d["nbs_path"])
        qmdpath = joinpath(stage, replace(relnb, r"\.ipynb$" => ".qmd"))
        mkpath(dirname(qmdpath))
        write(qmdpath, render_notebook(nbpath, cfg; index = index))
    end
    outrel = relpath(cfg.d["doc_path"], stage)
    write(joinpath(stage, "_quarto.yml"), quarto_yml(outrel, cfg.lib_name))
    return stage
end

"""
    render_docs(cfg=Config.load_config(); index=build_symbol_index(cfg))

Stage every notebook (see `stage_docs`), then shell out to `quarto
render .` from the staging directory to build the HTML site at
`cfg.doc_path`. Requires the `quarto` CLI on `PATH`. Returns `true` on
success (`quarto`'s own stdout/stderr stream through live).
"""
function render_docs(cfg::Config.NBConfig = Config.load_config(); index::Dict = build_symbol_index(cfg))
    Sys.which("quarto") === nothing && error(
        "`quarto` was not found on PATH. Install it from https://quarto.org/docs/get-started/.")
    stage = stage_docs(cfg; index = index)
    proc = run(Cmd(`quarto render .`; dir = stage); wait = false)
    wait(proc)
    return success(proc)
end

end # module NbQuarto
