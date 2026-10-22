"""
Project scaffolding: the Julia analog of nbdev's `nbdev_new`/
`nbdev_create_config`. Generates a real Julia package via `PkgTemplates.jl`
(License/Git/Tests/GitHubActions/Codecov/CompatHelper/TagBot/Dependabot),
then layers on the nbdev-style pieces: `nbs/index.ipynb` and
`nbs/00_core.ipynb` (using nbdev's own directive syntax), the `[nbdev]`
config table in `Project.toml`, and `.gitignore` entries for Quarto/Jupyter
build state.

Only local files and local git config are touched — no GitHub remote is
created or pushed to, and no network calls happen beyond what
`PkgTemplates.jl` itself does (registry lookups).
"""
module Scaffold

export scaffold

using ..NbIO
using PkgTemplates

function _git_get(key::String)
    try
        out = strip(read(`git config --get $key`, String))
        return isempty(out) ? nothing : out
    catch
        return nothing
    end
end

function _github_user_from_remote()
    url = _git_get("remote.origin.url")
    url === nothing && return nothing
    m = match(r"github\.com[:/]([^/]+)/", url)
    return m === nothing ? nothing : String(m.captures[1])
end

const NBDEV_TABLE = """

[nbdev]
nbs_path = "nbs"
doc_path = "_docs"
src_path = "src"
readme_nb = "index.ipynb"
recursive = true
clean_ids = true
clear_all = false
branch = "main"
cell_timeout = 600
"""

function _add_nbdev_table!(projfile::AbstractString)
    txt = read(projfile, String)
    occursin("[nbdev]", txt) && return nothing
    write(projfile, rstrip(txt) * "\n" * NBDEV_TABLE)
    return nothing
end

const GITIGNORE_EXTRA = """

# nbdev: docs build output and Quarto/Jupyter working state
/_docs/
/_proc/
.quarto/
.ipynb_checkpoints/
.last_checked
.gitconfig
"""

function _append_gitignore!(path::AbstractString)
    txt = isfile(path) ? read(path, String) : ""
    occursin("# nbdev:", txt) && return nothing
    write(path, rstrip(txt) * "\n" * GITIGNORE_EXTRA)
    return nothing
end

function _write_nbdev_layer!(root::AbstractString, name::AbstractString, description::AbstractString)
    nbs = joinpath(root, "nbs")
    mkpath(nbs)

    _add_nbdev_table!(joinpath(root, "Project.toml"))
    _append_gitignore!(joinpath(root, ".gitignore"))

    desc_line = isempty(description) ? "> Fill in a description here" : "> $(description)"
    index_nb = NbIO.new_notebook([
        NbIO.markdown_cell("# $(name)\n\n$(desc_line)"),
        NbIO.code_cell("#| hide\nusing $(name)"),
        NbIO.markdown_cell("## Install\n\n```julia\nusing Pkg\nPkg.add(path=\"$(root)\")\n```"),
        NbIO.markdown_cell("## How to use\n\nFill this in as functionality is built."),
    ])
    NbIO.write_nb(index_nb, joinpath(nbs, "index.ipynb"))

    core_nb = NbIO.new_notebook([
        NbIO.markdown_cell("# core\n\n> Fill in a module description here"),
        NbIO.code_cell("#| default_exp core"),
        NbIO.code_cell("#| export\nfoo() = nothing"),
    ])
    NbIO.write_nb(core_nb, joinpath(nbs, "00_core.ipynb"))
    return nothing
end

"""
    scaffold(name; dir=pwd(), user=nothing, author=nothing, author_email=nothing,
             description="", license="MIT", julia_version=v"1.10")

Scaffold a brand-new nbdev project named `name` in `joinpath(dir, name)`.

`author`/`author_email` default to `git config user.name`/`user.email`.
`user` (GitHub username — used only to build URLs/badges in the generated
files; no remote is created) is inferred from `git config --get
remote.origin.url` or `git config --get github.user` if not given
explicitly, and an error asks for it if neither is available.

Returns the path to the new project.
"""
function scaffold(
    name::AbstractString;
    dir::AbstractString = pwd(),
    user::Union{Nothing,AbstractString} = nothing,
    author::Union{Nothing,AbstractString} = nothing,
    author_email::Union{Nothing,AbstractString} = nothing,
    description::AbstractString = "",
    license::AbstractString = "MIT",
    julia_version::VersionNumber = v"1.10",
)
    author = something(author, _git_get("user.name"), "")
    author_email = something(author_email, _git_get("user.email"), "")
    isempty(author) && @warn "No author name found (git config user.name unset); generated files will credit no one. Pass `author=` explicitly."

    resolved_user = something(user, _github_user_from_remote(), _git_get("github.user"), Some(nothing))
    resolved_user === nothing && error(
        "Couldn't infer a GitHub username from `git config` (no `remote.origin.url` or `github.user` set). " *
        "Pass `user=\"yourname\"` explicitly.")

    authors_vec = isempty(author_email) ? [author] : ["$(author) <$(author_email)>"]

    t = PkgTemplates.Template(;
        user = String(resolved_user),
        authors = authors_vec,
        dir = String(dir),
        julia = julia_version,
        plugins = [
            PkgTemplates.License(; name = license),
            PkgTemplates.Git(),
            PkgTemplates.GitHubActions(),
            PkgTemplates.Codecov(),
            PkgTemplates.CompatHelper(),
            PkgTemplates.TagBot(),
            PkgTemplates.Dependabot(),
            PkgTemplates.Readme(),
            PkgTemplates.ProjectFile(),
            PkgTemplates.SrcDir(),
            PkgTemplates.Tests(),
        ],
    )
    t(String(name))

    root = joinpath(dir, name)
    _write_nbdev_layer!(root, name, description)
    return root
end

end # module Scaffold
