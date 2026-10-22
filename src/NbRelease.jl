"""
Release prep: the local, safe half of a release — bump `Project.toml`'s
version, regenerate `CHANGELOG.md` from git history, re-export and re-test
the project, and commit the result. The Julia analog of the version-
bump/changelog part of nbdev's `release.py` (`nbdev_bump_version`,
`nbdev_changelog`).

Deliberately does **not** reimplement nbdev's PyPI/conda uploader, and does
**not** tag, push, or touch any remote. Two independent reasons, not one:

1. Julia's own publishing convention already replaces what `release.py`'s
   uploader exists for — register a package by commenting
   `@JuliaRegistrator register` on a commit (the Registrator GitHub App
   opens a PR against the General registry; once merged, TagBot creates
   the git tag and GitHub release automatically). There is no PyPI-style
   artifact to build or upload; reimplementing that step would mean
   reimplementing registry PRs and GitHub bot interactions, not porting
   nbdev's actual logic.
2. Both of those steps need a real GitHub remote, which this project
   doesn't have (see `instruction_to_self.md`'s decisions — the `NBJulia`
   repo is local-only, by design) and are exactly the kind of
   visible-to-others, hard-to-reverse actions this project's own safety
   rules say to never take without being explicitly asked each time —
   whereas a local commit on a project with no remote is cheap to undo.

`prep_release` stops right after the version-bump commit and prints the
exact next manual commands instead.
"""
module NbRelease

export bump_version, changelog, prep_release

using ..Config
using ..Export
using ..NbTest
using TOML

"""
Parse a `\"X.Y.Z\"` (optionally `-prerelease`/`+buildmetadata`-suffixed)
semver string into a `(major, minor, patch)` tuple of `Int`s, discarding
any suffix. The suffix is accepted (not just tolerated) because
`NBJulia.scaffold`'s own PkgTemplates-generated `Project.toml` defaults to
`version = "1.0.0-DEV"` — rejecting it would make `bump_version`/
`prep_release` fail on every freshly-scaffolded project's first release
(confirmed: every one of the 10 independent stress-test agents hit this).
Dropping the suffix on bump is also the semantically right move: a real
release shouldn't carry a `-DEV` tag forward.
"""
function parse_semver(s::AbstractString)
    m = match(r"^(\d+)\.(\d+)\.(\d+)(?:[-+].*)?$", s)
    m === nothing && error("parse_semver: \"$s\" isn't a plain X.Y.Z (optionally -prerelease/+build) semver string.")
    return (parse(Int, m.captures[1]), parse(Int, m.captures[2]), parse(Int, m.captures[3]))
end

"""
    bump_version(; cfg = Config.load_config(), level = :patch)

Bump the `version` field of `cfg.root`'s `Project.toml` (`level` one of
`:major`/`:minor`/`:patch`), rewriting only that one line and leaving
everything else in the file byte-for-byte untouched (the same
don't-reformat-what-you-don't-own approach `Export.update_main_module!`
already uses for the main module file). Returns the new version string.
"""
function bump_version(; cfg::Config.NBConfig = Config.load_config(), level::Symbol = :patch)
    level in (:major, :minor, :patch) ||
        error("bump_version: level must be :major, :minor, or :patch, got :$level")
    toml_path = joinpath(cfg.root, "Project.toml")
    proj = TOML.parsefile(toml_path)
    haskey(proj, "version") || error("bump_version: $toml_path has no top-level `version` key.")
    major, minor, patch = parse_semver(proj["version"])
    newver = level === :major ? "$(major + 1).0.0" :
             level === :minor ? "$major.$(minor + 1).0" :
             "$major.$minor.$(patch + 1)"
    txt = read(toml_path, String)
    m = match(r"^version\s*=\s*\"[^\"]*\""m, txt)
    m === nothing && error("bump_version: couldn't find a `version = \"...\"` line in $toml_path.")
    stop = m.offset + ncodeunits(m.match)
    write(toml_path, txt[1:prevind(txt, m.offset)] * "version = \"$newver\"" * txt[stop:end])
    return newver
end

"The most recent annotated git tag reachable from `HEAD`, or `nothing` if there are none."
function last_tag(root::AbstractString)
    s = try
        strip(read(`git -C $root describe --tags --abbrev=0`, String))
    catch
        ""
    end
    return isempty(s) ? nothing : s
end

"""
The commit hash of the most recent `prep_release` commit (message starting
with the literal `Release v`), or `nothing` if there's never been one.
`prep_release` deliberately never tags (see the module docstring), so this
is what changelog generation falls back to instead of annotated git tags
for a project following this tool's own default workflow — without this,
`changelog`'s "since the last tag" basis would silently mean "since the
repo's first commit" on *every* call, duplicating the entire history into
every subsequent release's section (confirmed: 4 of the 10 independent
stress-test agents hit this).
"""
function last_release_commit(root::AbstractString)
    s = try
        strip(read(`git -C $root log --grep=^Release\ v --format=%H -n 1`, String))
    catch
        ""
    end
    return isempty(s) ? nothing : s
end

"""
    changelog(; cfg = Config.load_config(), path = joinpath(cfg.root, "CHANGELOG.md"))

Prepend a new `## vX.Y.Z` section to `path` (created if it doesn't exist
yet) listing every git commit subject since whichever is more specific of
(a) the last annotated tag reachable from `HEAD`, or (b) the last
`prep_release` commit (see `last_release_commit`) — falling back to every
commit since the repo's first, oldest first, if neither exists yet (a
project's genuine first-ever release). `X.Y.Z` is read from the *current*
`Project.toml` version, so call this *after* `bump_version` if you want
the new version's number on the new section. `cfg.root` must be inside a
git repository.
"""
function changelog(;
    cfg::Config.NBConfig = Config.load_config(),
    path::AbstractString = joinpath(cfg.root, "CHANGELOG.md"),
)
    since = something(last_tag(cfg.root), last_release_commit(cfg.root), Some(nothing))
    range = since === nothing ? "HEAD" : "$(since)..HEAD"
    raw = read(`git -C $(cfg.root) log --reverse --pretty=format:%s $range`, String)
    subjects = filter(!isempty, split(raw, '\n'))
    version = TOML.parsefile(joinpath(cfg.root, "Project.toml"))["version"]
    bullets = if isempty(subjects)
        since_label = something(last_tag, "the first commit")
        "- (no commits since $(since_label))\n"
    else
        join(("- " * s for s in subjects), "\n") * "\n"
    end
    section = "## v$version\n\n$(bullets)\n"
    existing = isfile(path) ? read(path, String) : ""
    write(path, section * existing)
    return path
end

"""
    prep_release(; cfg = Config.load_config(), level = :patch)

The safe, local half of a release: re-export every notebook, run the full
test suite (erroring out, with *no* version bump and *no* commit, if
anything fails — never release on top of a broken build), bump
`Project.toml`'s version, prepend a changelog section, and commit
everything (`"Release vX.Y.Z"`). Does not tag, push, or touch any remote
— see the module docstring for why — and prints the exact next manual
commands instead. Returns the new version string.
"""
function prep_release(; cfg::Config.NBConfig = Config.load_config(), level::Symbol = :patch)
    Export.export_project(; cfg = cfg)
    NbTest.test_project(; cfg = cfg) ||
        error("prep_release: one or more notebooks failed testing; fix them before releasing.")
    since = something(last_tag(cfg.root), last_release_commit(cfg.root), Some(nothing))
    if since !== nothing
        head = strip(read(`git -C $(cfg.root) rev-parse HEAD`, String))
        since == head && error("prep_release: no commits since the last release ($(since[1:7])) — nothing to release.")
    end
    newver = bump_version(; cfg = cfg, level = level)
    changelog(; cfg = cfg)
    run(`git -C $(cfg.root) add -A`)
    run(`git -C $(cfg.root) commit -q -m "Release v$newver"`)
    println(
        "Committed Release v$newver. Next, manually: `git -C $(cfg.root) tag v$newver && ",
        "git -C $(cfg.root) push --tags` — and, once a GitHub remote exists, comment ",
        "`@JuliaRegistrator register` on this commit to submit to the General registry.",
    )
    return newver
end

end # module NbRelease
