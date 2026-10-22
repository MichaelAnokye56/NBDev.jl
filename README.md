# NBJulia

[![Build Status](https://github.com/MichaelAnokye56/NBJulia.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/MichaelAnokye56/NBJulia.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/MichaelAnokye56/NBJulia.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/MichaelAnokye56/NBJulia.jl)

Notebook-driven development for Julia — modeled on Jeremy Howard's
[nbdev](https://nbdev.fast.ai). Write code, tests, and docs together in a
single Jupyter notebook; export the tagged code to a real importable
package; run the notebooks themselves as your test suite; generate a
Quarto documentation site; get git merge/diff drivers that resolve
notebook conflicts cell-by-cell instead of as raw JSON.

## Install

```julia
using Pkg
Pkg.add(url="https://github.com/MichaelAnokye56/NBJulia.jl")
```

(Not yet registered in the Julia General registry — see below.)

## Quickstart

```julia
using NBJulia

# 1. Scaffold a new package (wraps PkgTemplates.jl + an nbdev-style nbs/ layout)
NBJulia.scaffold("MyLib"; dir = pwd(), user = "yourgithubuser",
                  author = "Your Name", author_email = "you@example.com")

# 2. Write a notebook under MyLib/nbs/ — see "Directive syntax" below —
#    then export it into MyLib/src/:
cd("MyLib"); using Pkg; Pkg.activate(".")
NBJulia.export_project()

# 3. Run every notebook as your test suite:
NBJulia.test_project()

# 4. Build a docs site (needs the `quarto` CLI on PATH):
NBJulia.render_docs()

# 5. Wire up git so merge conflicts resolve cell-by-cell, not as raw JSON:
NBJulia.install_hooks()

# 6. Round-trip a hand-edit made directly in a generated .jl file back
#    into the notebook it came from:
NBJulia.sync_project()

# 7. Local release prep — version bump, changelog, a tested/committed release:
NBJulia.prep_release()
```

## Directive syntax (inside a notebook code cell, as a `#|`-prefixed comment)

Unchanged from nbdev — a Julia comment is also `#`, so this is literally
the same grammar:

| directive | effect |
| --- | --- |
| `#\| default_exp name` | sets this notebook's default export target module (`name` → `src/name.jl`; dots nest into folders, e.g. `sub.core` → `src/sub/core.jl`) |
| `#\| export` | cell's code is written to the target module **and** its top-level names are added to the package's `export` list |
| `#\| export name` | same, but targets module `name` instead of the notebook's default |
| `#\| exports` | alias for `#\| export` |
| `#\| exporti` | cell's code is written to the target module, but its names stay **private** (not added to `export`) |
| `#\| exportd` | alias for `#\| exporti` |
| `#\| hide` | invisible to both export and docs rendering, but still *runs* in tests/docs |
| `#\| notest` | skipped during `test_project`/`test_nb` (default skip-flag) |
| `#\| eval: false` / `#\| eval: true` | force a cell to never/always run, overriding `notest` |

A markdown cell starting with `# ` (a level-1 heading) becomes part of the
target module's docstring. Directive comment lines are always stripped
out of the code actually written to the library file.

Use `#| hide` + `using MyLib` as the second cell of a notebook (scaffold
adds this automatically) to make earlier-exported code available to later
cells, in that notebook or any other — every notebook's export target is
`include()`-d into the one package module, so they already share a single
namespace with no explicit import needed between them.

**Never** tag a cell doing `using MyLib`/`import MyLib` (the package's own
name) with an export directive — `export_project`/`nb_export` refuse this
with a clear error (a package importing itself is nonsensical, and on at
least one tested Julia version it hung the loader rather than erroring
cleanly, though that could not be reproduced on more recent Julia).

## Command reference

| function | what it does |
| --- | --- |
| `scaffold(name; dir, user, author, author_email, ...)` | create a new project (PkgTemplates + nbdev-style `nbs/` layout) |
| `load_config(path=pwd())` | read the `[nbjulia]` table out of the nearest `Project.toml` |
| `export_project()` / `nb_export(nbpath)` | export every / one notebook's tagged cells into `src/` |
| `test_project()` / `test_nb(path)` | re-execute every / one notebook's cells as tests |
| `build_symbol_index(cfg)` | where every exported name is defined |
| `show_doc(x)` | a symbol's rendered docstring + signature |
| `render_notebook(nbpath, cfg)` | one notebook → Quarto markdown |
| `stage_docs()` / `render_docs()` | build the Quarto docs site |
| `clean_nb(path)` / `clean_project()` | strip git-diff noise (execution counts, volatile metadata, output noise) from notebooks |
| `install_hooks()` | wire up the clean filter + merge/diff drivers in this git repo |
| `sync_project()` | pull a hand-edit made directly in a generated `.jl` file back into its notebook |
| `bump_version(; level)` / `changelog()` / `prep_release(; level)` | local release prep: version bump, changelog from git history, a tested/committed release |

## Troubleshooting

**`using .MyLib` fails with `UndefVarError: MyLib not defined`.** The
leading dot means *relative* import. For a plain script or notebook cell,
use the absolute form: `using MyLib`.

**Precompile fails with `Cannot load module X ... because package MyLib
does not have X in its dependencies`.** If exported code does `using
X`/`import X` — including a stdlib — `X` must be a real dependency of
*your* package (`Pkg.add("X")` from inside it), not just installed
somewhere on the system.

**`ERROR: importing MyLib into Main conflicts with an existing global.`**
The current Julia session already has an older copy of `MyLib` loaded.
Restart the session after any source change — `Revise.jl` can avoid this
for ordinary function-body edits, but not for redefining a `struct`/
abstract-type hierarchy.

**`git log -p`/`git show` print raw JSON instead of a nice diff.** Pass
`--ext-diff` explicitly (`git log -p --ext-diff`); plain `git diff`
already honors the driver with no extra flag — this is standard git
behavior (external diff drivers are off by default for `log`/`show`), not
an NBJulia bug.

## Known limitations

- `export_project`'s `include()` ordering follows notebook discovery
  order (`00_`/`01_`/`02_` numbering), not real dependency analysis — a
  genuinely *reversed* dependency against your own numbering will still
  break precompilation.
- A bare name that happens to collide with an existing `Base` export
  (`length`, `isempty`, `abs`, ...) is exported without a warning, and
  will break that name for every downstream caller once `using`d.
- `sync_project` doesn't detect a true three-way conflict (the notebook
  cell and the generated `.jl` file both independently edited since the
  last export) — the `.jl` file always wins silently.
- No per-cell timeout in `test_nb`/`render_notebook`; no stdout/stderr
  capture during test or docs execution (only a cell's computed value);
  `build_symbol_index` has no cross-package lookup and can misattribute an
  entry on a name collision; `install_hooks` doesn't commit
  `.gitattributes` itself.
- `prep_release` deliberately never tags, pushes, or submits to a
  registry — see the next section.

## Releasing

`prep_release()` does only the safe, local half of a release (version
bump, changelog, a tested commit) and stops there. Julia's own publishing
convention already covers the rest: once this package has a real GitHub
remote, comment `@JuliaRegistrator register` on the release commit — the
[Registrator](https://github.com/JuliaRegistries/Registrator.jl) GitHub
App opens a PR against the
[General registry](https://github.com/JuliaRegistries/General); once
merged, [TagBot](https://github.com/JuliaRegistries/TagBot) creates the
git tag and GitHub release automatically. No separate upload step, and
nothing JuliaHub-specific to do — registered packages show up on
[JuliaHub's public listing](https://juliahub.com/ui/Packages) automatically.

## Status

Built in phases, dogfooded on itself throughout, and stress-tested by 10
independent agents each building a real package through the full
lifecycle and trying to break it — see this repo's commit history for the
fixes that came out of that. 291 tests pass (`Pkg.test()`).

## License

MIT — see [LICENSE](LICENSE).
