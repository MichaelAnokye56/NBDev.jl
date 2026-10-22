"""
Project configuration: reads the `[nbdev]` table out of the nearest
`Project.toml`, the same way nbdev reads `[tool.nbdev]` out of
`pyproject.toml`. No separate config file needed — Julia's `Project.toml`
is already TOML, and both `Pkg` and the `TOML` stdlib tolerate the extra
table (verified empirically; see
`../../ReverseEngineered/nbdev_files/ARCHITECTURE.md`).
"""
module Config

export NBConfig, find_project_toml, load_config, find_notebooks

using TOML

const DEFAULTS = Dict{String,Any}(
    "nbs_path" => "nbs",
    "doc_path" => "_docs",
    "src_path" => "src",
    "readme_nb" => "index.ipynb",
    "recursive" => true,
    "clean_ids" => true,
    "clear_all" => false,
    "branch" => "main",
    "cell_timeout" => 600,
)

"""
    find_project_toml(start=pwd())

Walk upward from `start` looking for the nearest `Project.toml` (or
`JuliaProject.toml`). Returns the path, or `nothing` if none is found.
"""
function find_project_toml(start::AbstractString = pwd())
    dir = abspath(start)
    while true
        for name in ("Project.toml", "JuliaProject.toml")
            p = joinpath(dir, name)
            isfile(p) && return p
        end
        parent = dirname(dir)
        parent == dir && return nothing
        dir = parent
    end
end

"""
    NBConfig

Resolved project configuration: the project root directory plus every key
from `[nbdev]` (merged over `DEFAULTS`), with path-valued keys
(`nbs_path`, `doc_path`, `src_path`) resolved to absolute paths.
"""
struct NBConfig
    root::String
    lib_name::String
    d::Dict{String,Any}
end

function Base.getproperty(c::NBConfig, k::Symbol)
    k === :root && return getfield(c, :root)
    k === :lib_name && return getfield(c, :lib_name)
    k === :d && return getfield(c, :d)
    return getfield(c, :d)[String(k)]
end

Base.get(c::NBConfig, k::AbstractString, default=nothing) = get(c.d, k, default)

const _PATH_KEYS = ("nbs_path", "doc_path", "src_path")

"""
    load_config(path=pwd())

Load the `[nbdev]` table from the nearest `Project.toml` to `path`,
merged over `DEFAULTS`. Raises if no `Project.toml` is found.
"""
function load_config(path::AbstractString = pwd())
    toml_path = find_project_toml(path)
    toml_path === nothing && error(
        "No Project.toml found walking up from $(abspath(path)). " *
        "nbdev commands must run inside a Julia project.")
    root = dirname(toml_path)
    proj = TOML.parsefile(toml_path)
    nbdev = get(proj, "nbdev", Dict{String,Any}())
    d = merge(DEFAULTS, nbdev)
    for k in _PATH_KEYS
        d[k] = joinpath(root, d[k])
    end
    lib_name = get(proj, "name", basename(root))
    return NBConfig(root, lib_name, d)
end

_skip_name(n::AbstractString) = startswith(n, '.') || startswith(n, '_')

"""
    find_notebooks(cfg)

Every `.ipynb` file under `cfg.nbs_path`, sorted, skipping dot-/underscore-
prefixed files and folders; recurses if `cfg.recursive` is set. Shared by
`Export.export_project` and `NbTest.test_project` — the one place both
need to agree on "what counts as a project notebook."
"""
function find_notebooks(cfg::NBConfig)
    root = cfg.d["nbs_path"]
    isdir(root) || return String[]
    files = String[]
    if cfg.d["recursive"]
        for (dir, dirs, fs) in walkdir(root)
            filter!(d -> !_skip_name(d), dirs)
            for f in fs
                (endswith(f, ".ipynb") && !_skip_name(f)) && push!(files, joinpath(dir, f))
            end
        end
    else
        for f in readdir(root)
            full = joinpath(root, f)
            (isfile(full) && endswith(f, ".ipynb") && !_skip_name(f)) && push!(files, full)
        end
    end
    sort!(files)
    return files
end

end # module Config
