using NBJulia
using NBJulia: NbIO, Process, Export, Config, Scaffold, NbTest, NbDocs, NbQuarto, NbClean, NbGit, NbSync, NbRelease
using Test
using OrderedCollections
using Markdown

# ---------------------------------------------------------------------------
# Test fixture helpers (self-contained — no real .ipynb files needed)
# ---------------------------------------------------------------------------

"Build a minimal cell dict good enough for NbIO/Process/Export to operate on."
function mk_cell(cell_type::String, source::String)
    return OrderedDict{String,Any}(
        "cell_type" => cell_type,
        "source" => source,
        "metadata" => OrderedDict{String,Any}(),
        "id" => NbIO.new_cell_id(),
    )
end

"Like `mk_cell`, but with an explicit `id` (for tests that need to align cells across three notebook variants, e.g. a 3-way merge)."
function mk_cell_with_id(cell_type::String, source::String, id::String)
    c = mk_cell(cell_type, source)
    c["id"] = id
    return c
end

"Build a minimal notebook dict from a list of (cell_type, source) pairs."
function mk_nb(cells::Vector{Tuple{String,String}})
    return OrderedDict{String,Any}(
        "cells" => Any[mk_cell(t, s) for (t, s) in cells],
        "metadata" => OrderedDict{String,Any}("kernelspec" => OrderedDict{String,Any}("language" => "julia")),
        "nbformat" => 4,
        "nbformat_minor" => 5,
    )
end

"Scaffold a throwaway project dir (Project.toml + nbs/) under a temp dir, return its `Config.NBConfig`."
function temp_project(cells::Vector{Tuple{String,String}}; nbname = "core.ipynb")
    root = mktempdir()
    open(joinpath(root, "Project.toml"), "w") do io
        println(io, """
        name = "TestPkg"
        uuid = "00000000-0000-0000-0000-000000000000"
        version = "0.1.0"

        [nbjulia]
        nbs_path = "nbs"
        src_path = "src"
        doc_path = "_docs"
        """)
    end
    mkpath(joinpath(root, "nbs"))
    mkpath(joinpath(root, "src"))
    NbIO.write_nb(mk_nb(cells), joinpath(root, "nbs", nbname))
    return Config.load_config(root)
end

"`git init` (on `main`) a `temp_project`-produced `cfg.root`, with a throwaway user identity, and one initial commit of whatever's already there."
function git_init!(cfg)
    run(`git -C $(cfg.root) init -q -b main`)
    run(`git -C $(cfg.root) config user.email test@test.com`)
    run(`git -C $(cfg.root) config user.name test`)
    run(`git -C $(cfg.root) add -A`)
    run(`git -C $(cfg.root) commit -q -m "initial commit"`)
    return cfg
end

"Fixture module with known docstring/no-docstring cases for NbDocs tests."
module DocsFixture
"""
    greet(name)

Says hello to `name`.
"""
greet(name) = "Hello, $name!"

"A simple point."
struct Point
    x::Int
    y::Int
end

nodoc(x) = x

"doc for the keyword-colliding function"
function var"export"(x)
    x
end
end

# ---------------------------------------------------------------------------

@testset "NBJulia.jl" begin
    @testset "directive parsing" begin
        @test NbIO.parse_directive("#| export") == ("export" => "")
        @test NbIO.parse_directive("#|export") == ("export" => "")
        @test NbIO.parse_directive("  #|  hide") == ("hide" => "")
        @test NbIO.parse_directive("#| default_exp core") == ("default_exp" => "core")
        @test NbIO.parse_directive("#| eval: false") == ("eval" => "false")
        @test NbIO.parse_directive("#| filter_stream: foo bar") == ("filter_stream" => "foo bar")
        @test NbIO.parse_directive("x = 1") === nothing
        @test NbIO.parse_directive("# a regular comment") === nothing
    end

    @testset "partition_source" begin
        src = "#| export\n#| eval: false\n\nfunction foo()\n    1\nend\n"
        dirs, code = NbIO.partition_source(src)
        @test length(dirs) == 3  # two directive lines + one blank line
        @test join(code) == "function foo()\n    1\nend\n"
    end

    @testset "cell_directives / strip_directive_lines" begin
        cell = mk_cell("code", "#| export\n#| default_exp core\nfoo() = 1\n")
        dirs = NbIO.cell_directives(cell)
        @test dirs == Dict("export" => "", "default_exp" => "core")
        @test NbIO.has_directive(cell, "export")
        @test !NbIO.has_directive(cell, "hide")
        @test NbIO.strip_directive_lines(NbIO.cell_source(cell)) == "foo() = 1\n"
    end

    @testset "hidden cell (source = nothing) is dropped after a pass" begin
        nb = mk_nb([("code", "#| hide\nx = 1\n"), ("code", "y = 2\n")])
        struct HideAll <: Process.Processor end
        Process.on_cell!(::HideAll, cell) = NbIO.has_directive(cell, "hide") && (cell["source"] = nothing)
        Process.process!(Process.NBProcessor(nb, HideAll()))
        @test length(nb["cells"]) == 1
        @test NbIO.cell_source(nb["cells"][1]) == "y = 2\n"
    end

    @testset "toplevel_names (AST walk for the auto export list)" begin
        function nm(src)
            e, _ = Meta.parse(src, 1)
            return Export.toplevel_names(e)
        end
        @test nm("function foo(x)\n x\nend") == ["foo"]
        @test nm("foo(x; y=1) = x + y") == ["foo"]
        @test nm("const BAR = 1") == ["BAR"]
        @test nm("BAZ = 1") == ["BAZ"]
        @test nm("struct Foo\n a::Int\nend") == ["Foo"]
        @test nm("mutable struct Foo{T} <: Number\n a::T\nend") == ["Foo"]
        @test nm("macro foo(x)\n x\nend") == ["@foo"]
        @test nm("Base.show(io::IO, x::Foo) = print(io, \"Foo\")") == []
        @test nm("println(\"side effect\")") == []
        @test nm("\"\"\"a doc\"\"\"\nfoo(x) = x") == ["foo"]

        # The bug report this guards: names defined inside a `begin...end`
        # block were silently dropped (the walker had no `:block` case at
        # all — the whole block just fell through to "no name").
        @test nm("""
            begin
                struct Foo
                    x::Int
                end
                abstract type Bar end
                baz(x) = x
            end
            """) == ["Foo", "Bar", "baz"]

        # Nested blocks, and a block mixed with a doc-macrocall-wrapped def.
        @test nm("""
            begin
                begin
                    abstract type Inner end
                end
                \"\"\"doc\"\"\"
                qux(x) = x
            end
            """) == ["Inner", "qux"]

        # The bug report this guards: `Meta.parse` wraps a statement
        # followed by a trailing `;` in an `Expr(:toplevel, ...)` — a
        # very ordinary Jupyter/Julia idiom to suppress a value (`foo(x) =
        # x + 1;`) — which the walker had no case for at all, so the name
        # was silently dropped from `export` even though the code itself
        # was still written to the generated file.
        @test nm("foo(x) = x + 1;") == ["foo"]
        @test nm("struct Foo\n x::Int\nend;") == ["Foo"]
        @test nm("a = 1; b = 2") == ["a", "b"]
    end

    @testset "self-import guard (catches a real loader deadlock at export time instead)" begin
        parsed(src) = first(Meta.parse(src, 1))
        @test Export.imported_package_names(parsed("using MyLib")) == ["MyLib"]
        @test Export.imported_package_names(parsed("using MyLib: foo")) == ["MyLib"]
        @test Export.imported_package_names(parsed("using MyLib, Other")) == ["MyLib", "Other"]
        @test Export.imported_package_names(parsed("using .MyLib")) == []  # relative — not a self-import risk
        @test Export.imported_package_names(parsed("import MyLib")) == ["MyLib"]
        @test Export.imported_package_names(parsed("foo(x) = x")) == []
        # `import X as Y` used to bypass the guard entirely (confirmed by a
        # stress-test agent) — an ordinary, easy-to-reach-for import form,
        # not an exotic one. (Bare `using X as Y` isn't valid Julia syntax
        # at all — renaming via `using` requires the colon form, `using X:
        # X as Y` — so only the `import` form needs covering here.)
        @test Export.imported_package_names(parsed("import MyLib as ML")) == ["MyLib"]
        @test_throws ErrorException Export.check_no_self_import("import MyLib as ML", "MyLib", "ctx")

        @test_nowarn Export.check_no_self_import("using Other", "MyLib", "ctx")
        @test_throws ErrorException Export.check_no_self_import("using MyLib", "MyLib", "ctx")
        @test_throws ErrorException Export.check_no_self_import("x = 1\nusing MyLib: foo", "MyLib", "ctx")

        # The actual regression this guards: exporting a cell that `using`s its
        # own package must fail loudly at export time, not hang when loaded.
        cfg = temp_project([
            ("code", "#| default_exp core"),
            ("code", "#| export\nusing TestPkg\nfoo() = 1"),
        ])
        @test_throws ErrorException Export.export_project(; cfg = cfg)

        # But a `#| hide` cell doing the same thing is fine: hide-only cells
        # are never routed into any export bucket, so they can't deadlock.
        cfg2 = temp_project([
            ("code", "#| default_exp core"),
            ("code", "#| hide\nusing TestPkg"),
            ("code", "#| export\nfoo() = 1"),
        ])
        res = Export.export_project(; cfg = cfg2)
        @test res.exportnames == ["foo"]
        written = read(joinpath(cfg2.d["src_path"], "core.jl"), String)
        @test !occursin("using TestPkg", written)
    end

    @testset "export_project: full round trip in an isolated temp project" begin
        cfg = temp_project([
            ("markdown", "# core\n\n> Fill in a module description here"),
            ("code", "#| default_exp core"),
            ("code", "#| export\nfoo(x) = x + 1"),
            ("code", "#| exporti\n_helper() = 1"),
        ])
        res = Export.export_project(; cfg = cfg)
        @test res.relfiles == ["core.jl"]
        @test res.exportnames == ["foo"]  # _helper is exported-but-private: written, not in the public list

        written = read(joinpath(cfg.d["src_path"], "core.jl"), String)
        @test occursin("foo(x) = x + 1", written)
        @test occursin("_helper() = 1", written)
        @test !occursin("#|", written) # directive comments must be stripped
        @test occursin("# core", written) # module docstring from the markdown title cell

        mainfile = joinpath(cfg.d["src_path"], "TestPkg.jl")
        open(mainfile, "w") do io
            print(io, "module TestPkg\n\nend\n")
        end
        changed = Export.update_main_module!(mainfile, res.relfiles, res.exportnames)
        @test changed
        maintxt = read(mainfile, String)
        @test occursin("include(\"core.jl\")", maintxt)
        @test occursin("export foo", maintxt)
        @test !occursin("_helper", maintxt)

        # Re-running against the already-marked file replaces the block in place, idempotently.
        @test !Export.update_main_module!(mainfile, res.relfiles, res.exportnames)
    end

    @testset "export_project: a semicolon-terminated cell (common Jupyter output-suppression idiom) still gets its name exported" begin
        cfg = temp_project([
            ("code", "#| default_exp core"),
            ("code", "#| export\nfoo(x) = x + 1;"),
        ])
        res = Export.export_project(; cfg = cfg)
        @test "foo" in res.exportnames
        written = read(joinpath(cfg.d["src_path"], "core.jl"), String)
        @test occursin("foo(x) = x + 1;", written)
        mainfile = joinpath(cfg.d["src_path"], cfg.lib_name * ".jl")
        @test occursin("export foo", read(mainfile, String))
    end

    @testset "export_project: names grouped in a begin...end block are exported" begin
        cfg = temp_project([
            ("code", "#| default_exp core"),
            ("code", """
            #| export
            begin
                abstract type Shape end
                struct Circle <: Shape
                    r::Float64
                end
                area(c::Circle) = pi * c.r^2
            end
            """),
        ])
        res = Export.export_project(; cfg = cfg)
        @test Set(res.exportnames) == Set(["Shape", "Circle", "area"])
        written = read(joinpath(cfg.d["src_path"], "core.jl"), String)
        @test occursin("abstract type Shape end", written)
        @test occursin("struct Circle <: Shape", written)
    end

    @testset "collect_exported_names / is_exportable_name: unquoted Base.<op> extensions never produce an invalid export" begin
        # `Base.==(a,b) = true` (missing the `:()` quoting) parses as the
        # broadcast call `Base .== (a, b)` — its "name" really is the
        # literal `.==`, which used to flow straight into `export .==`
        # and fail the whole package's precompilation (confirmed empirically).
        @test Export.toplevel_defined_names("Base.==(a::Int,b::Int) = true") == [".=="]
        @test !Export.is_exportable_name(".==")
        @test Export.is_exportable_name("foo")
        @test Export.is_exportable_name("@mymacro")

        cfg = temp_project([
            ("code", "#| default_exp core"),
            ("code", "#| export\nstruct Pt\n    x::Int\nend\nBase.==(a::Pt,b::Pt) = a.x==b.x"),
        ])
        res = Export.export_project(; cfg = cfg)
        @test "Pt" in res.exportnames
        @test !(".==" in res.exportnames)
        mainfile = joinpath(cfg.d["src_path"], cfg.lib_name * ".jl")
        maintxt = read(mainfile, String)
        @test !occursin(".==", maintxt) # the generated export statement must stay valid Julia
    end

    @testset "nb_export / export_project: `#| default_exp` with no value gives a clear error, not a raw BoundsError" begin
        cfg = temp_project([("code", "#| default_exp")])
        nbpath = joinpath(cfg.root, "nbs", "core.ipynb")
        @test_throws ErrorException Export.nb_export(nbpath; cfg = cfg)
        try
            Export.nb_export(nbpath; cfg = cfg)
        catch e
            @test !(e isa BoundsError)
            @test occursin("default_exp", sprint(showerror, e))
        end
    end

    @testset "export_project: one malformed notebook's error names the file and doesn't block the others" begin
        cfg = temp_project([("code", "#| default_exp core"), ("code", "#| export\nfoo() = 1")])
        write(joinpath(cfg.root, "nbs", "bad.ipynb"), "{ not valid json")
        err = try
            Export.export_project(; cfg = cfg)
            nothing
        catch e
            e
        end
        @test err !== nothing
        msg = sprint(showerror, err)
        @test occursin("bad.ipynb", msg) # names the offending file
        # the good notebook was still exported as part of the same run
        @test isfile(joinpath(cfg.d["src_path"], "core.jl"))
    end

    @testset "Export.warn_unknown_directives: a typo'd directive warns instead of silently vanishing" begin
        cfg = temp_project([
            ("code", "#| default_exp core"),
            ("code", "#|exprot\ntypo_fn() = 1"),
            ("code", "#| export\ngood_fn() = 2"),
        ])
        nbpath = joinpath(cfg.root, "nbs", "core.ipynb")
        @test_logs (:warn, r"exprot") match_mode = :any Export.nb_export(nbpath; cfg = cfg)
        # and the code really is dropped, confirming the warning is accurate, not spurious
        written = read(joinpath(cfg.d["src_path"], "core.jl"), String)
        @test occursin("good_fn", written)
        @test !occursin("typo_fn", written)
    end

    @testset "export_project: index-style markdown-only notebook is silently skipped" begin
        cfg = temp_project([("markdown", "# TestPkg\n\n> a description")]; nbname = "index.ipynb")
        res = Export.export_project(; cfg = cfg)
        @test isempty(res.relfiles)
        @test isempty(res.exportnames)
    end

    @testset "export_project: include order follows notebook discovery order, not alphabetical module name" begin
        # The bug report this guards, confirmed by 4 independent stress-test
        # agents with 4 different natural projects: a type defined in one
        # notebook, referenced in a struct field's type annotation by a
        # *later-numbered* notebook whose own module name happens to sort
        # *before* the type-defining module's name alphabetically ("arithmetic"
        # < "core") used to get `include`d first, failing precompilation with
        # `UndefVarError: Pt not defined` since struct field types are
        # resolved eagerly at `include` time, not lazily like a function body.
        root = mktempdir()
        write(joinpath(root, "Project.toml"), """
        name = "OrderPkg"
        uuid = "00000000-0000-0000-0000-00000000face"
        version = "0.1.0"

        [nbjulia]
        nbs_path = "nbs"
        src_path = "src"
        """)
        mkpath(joinpath(root, "nbs"))
        NbIO.write_nb(
            mk_nb([("code", "#| default_exp core"), ("code", "#| export\nstruct Pt\n    x::Int\nend")]),
            joinpath(root, "nbs", "00_core.ipynb"),
        )
        NbIO.write_nb(
            mk_nb([
                ("code", "#| default_exp arithmetic"), # "arithmetic" < "core" alphabetically
                ("code", "#| export\nstruct Line\n    a::Pt\n    b::Pt\nend"),
            ]),
            joinpath(root, "nbs", "01_arithmetic.ipynb"),
        )
        cfg = Config.load_config(root)
        res = Export.export_project(; cfg = cfg)
        @test res.relfiles == ["core.jl", "arithmetic.jl"] # notebook order, not ["arithmetic.jl", "core.jl"]

        mainfile = joinpath(cfg.d["src_path"], "OrderPkg.jl")
        maintxt = read(mainfile, String)
        @test findfirst("include(\"core.jl\")", maintxt).start <
              findfirst("include(\"arithmetic.jl\")", maintxt).start

        # the real confirmation: the generated package actually precompiles.
        out = read(`julia --project=$root -e 'using OrderPkg; println("loaded OK: ", OrderPkg.Line)'`, String)
        @test occursin("loaded OK", out)
    end

    @testset "export_project: two notebooks appending to the same module" begin
        root = mktempdir()
        open(joinpath(root, "Project.toml"), "w") do io
            println(io, """
            name = "TestPkg2"
            uuid = "00000000-0000-0000-0000-000000000000"
            version = "0.1.0"

            [nbjulia]
            nbs_path = "nbs"
            src_path = "src"
            """)
        end
        mkpath(joinpath(root, "nbs"))
        NbIO.write_nb(
            mk_nb([("code", "#| default_exp core"), ("code", "#| export\nfoo() = 1")]),
            joinpath(root, "nbs", "00_core.ipynb"),
        )
        NbIO.write_nb(
            mk_nb([("code", "#| default_exp core"), ("code", "#| export\nbar() = 2")]),
            joinpath(root, "nbs", "01_more.ipynb"),
        )
        cfg = Config.load_config(root)
        res = Export.export_project(; cfg = cfg)
        @test res.relfiles == ["core.jl"]
        @test res.exportnames == ["bar", "foo"]
        written = read(joinpath(cfg.d["src_path"], "core.jl"), String)
        @test occursin("foo() = 1", written)
        @test occursin("bar() = 2", written)
    end

    @testset "scaffold: produces a working nbdev-style Julia package" begin
        dir = mktempdir()
        root = Scaffold.scaffold(
            "ScaffoldTestPkg"; dir = dir, user = "testuser",
            author = "Test Author", author_email = "test@example.com",
        )
        @test isfile(joinpath(root, "Project.toml"))
        @test isfile(joinpath(root, "src", "ScaffoldTestPkg.jl"))
        @test isfile(joinpath(root, "nbs", "index.ipynb"))
        @test isfile(joinpath(root, "nbs", "00_core.ipynb"))

        proj = read(joinpath(root, "Project.toml"), String)
        @test occursin("[nbjulia]", proj)
        @test occursin("name = \"ScaffoldTestPkg\"", proj)
        @test occursin("Test Author <test@example.com>", proj)

        cfg = Config.load_config(root)
        res = Export.export_project(; cfg = cfg)
        @test res.relfiles == ["core.jl"]
        @test res.exportnames == ["foo"]
    end

    @testset "does_cell_eval / select_test_cells" begin
        plain = mk_cell("code", "x = 1")
        notest = mk_cell("code", "#| notest\nx = 1")
        evalfalse = mk_cell("code", "#| eval: false\nx = 1")
        evaltrue = mk_cell("code", "#| notest\n#| eval: true\nx = 1") # eval directive overrides the skip-flag match
        md = mk_cell("markdown", "# hi")

        @test NbTest.does_cell_eval(plain, true) == true
        @test NbTest.does_cell_eval(md, true) == false  # never a code cell
        @test NbTest.does_cell_eval(evalfalse, true) == false
        @test NbTest.does_cell_eval(notest, true, Set(["notest"])) == false
        @test NbTest.does_cell_eval(notest, true, Set(["notest"]), Set(["notest"])) == true # force_flags cancels it
        @test NbTest.does_cell_eval(evaltrue, true, Set(["notest"])) == true # eval:true overrides the skip flag

        nb = mk_nb([("code", "a=1"), ("markdown", "# x"), ("code", "#| notest\nb=1"), ("code", "c=1")])
        sel = NbTest.select_test_cells(nb)
        @test length(sel) == 2 # the #|notest cell is skipped by default
        @test NbIO.cell_source.(sel) == ["a=1", "c=1"]
    end

    @testset "test_nb: passing notebook, various assertion styles" begin
        cfg = temp_project([
            ("code", "f(x) = x + 1"),
            ("code", "@assert f(1) == 2"),
            ("code", "using Test\n@test f(2) == 3"),
            ("code", "#| notest\nerror(\"this must not run by default\")"),
        ])
        nbpath = joinpath(cfg.d["nbs_path"], "core.ipynb")
        passed, elapsed, err = NbTest.test_nb(nbpath)
        @test passed
        @test err === nothing
        @test elapsed >= 0
    end

    @testset "test_nb: failing cell is reported with the right cell index/id" begin
        cfg = temp_project([
            ("code", "f(x) = x + 1"),
            ("code", "@assert f(1) == 2"),
            ("code", "@assert f(1) == 999"),  # fails here: 3rd selected cell (index 3)
            ("code", "x = 1"),                # never reached
        ])
        nbpath = joinpath(cfg.d["nbs_path"], "core.ipynb")
        passed, elapsed, err = NbTest.test_nb(nbpath)
        @test !passed
        @test err !== nothing
        @test err.idx == 3
        @test err.error isa AssertionError
    end

    @testset "test_nb: #| eval: false cell is skipped" begin
        cfg = temp_project([
            ("code", "#| eval: false\nerror(\"must not run\")"),
            ("code", "x = 1"),
        ])
        nbpath = joinpath(cfg.d["nbs_path"], "core.ipynb")
        passed, _, _ = NbTest.test_nb(nbpath)
        @test passed
    end

    @testset "test_project: aggregates pass/fail across notebooks" begin
        root = mktempdir()
        write(joinpath(root, "Project.toml"), """
        name = "TestPkg3"
        uuid = "00000000-0000-0000-0000-000000000000"
        version = "0.1.0"

        [nbjulia]
        nbs_path = "nbs"
        """)
        mkpath(joinpath(root, "nbs"))
        NbIO.write_nb(mk_nb([("code", "@assert 1 == 1")]), joinpath(root, "nbs", "00_good.ipynb"))
        NbIO.write_nb(mk_nb([("code", "@assert 1 == 2")]), joinpath(root, "nbs", "01_bad.ipynb"))
        cfg = Config.load_config(root)
        @test NbTest.test_project(; cfg = cfg) == false  # one notebook fails

        NbIO.write_nb(mk_nb([("code", "@assert 1 == 1")]), joinpath(root, "nbs", "01_bad.ipynb"))
        @test NbTest.test_project(; cfg = cfg) == true  # now both pass
    end

    @testset "test_project: a malformed notebook fails cleanly, doesn't abort the other notebooks' tests" begin
        cfg = temp_project([("code", "#| default_exp core"), ("code", "@assert 1 == 1")])
        write(joinpath(cfg.root, "nbs", "bad.ipynb"), "{ not valid json")
        @test NbTest.test_project(; cfg = cfg) == false
        passed, _, _ = NbTest.test_nb(joinpath(cfg.root, "nbs", "core.ipynb"))
        @test passed # the good notebook is unaffected by its malformed sibling
    end

    @testset "NbDocs.show_doc" begin
        md1 = NbDocs.show_doc(DocsFixture.greet)
        @test md1 isa Markdown.MD
        s1 = string(md1)
        @test occursin("greet", s1)
        @test occursin("Says hello", s1)

        md2 = NbDocs.show_doc(DocsFixture.Point)
        @test occursin("simple point", string(md2))

        md3 = NbDocs.show_doc(DocsFixture.nodoc)
        @test occursin("No documentation found", string(md3))

        md4 = NbDocs.show_doc("doesnotexist_xyz"; mod = DocsFixture)
        s4 = string(md4)
        @test occursin("does not exist", s4) || occursin("No documentation found", s4)

        # a name that collides with a Julia keyword (reachable only via
        # `var"export"`) used to silently fail — `Meta.parse("@doc " *
        # "export")` chokes on the keyword, and the fallback to "no
        # docstring found" hid a real docstring that does exist. Confirmed
        # by a stress-test agent; also confirmed separately that a bare
        # `Symbol`-based lookup resolves to the *keyword's* built-in doc
        # instead of the user's binding, so this must go through the
        # qualified `Mod.name` form, not just avoid the parser.
        md5 = NbDocs.show_doc(DocsFixture.var"export")
        @test occursin("doc for the keyword-colliding function", string(md5))

        # name-string lookup form
        md5 = NbDocs.show_doc("greet"; mod = DocsFixture)
        @test occursin("Says hello", string(md5))

        # index-based "defined in" footer
        idx = Dict("greet" => NbDocs.SymbolEntry("greet", "core.jl", "00_core.ipynb", "abcd1234"))
        md6 = NbDocs.show_doc(DocsFixture.greet; index = idx)
        s6 = string(md6)
        @test occursin("00_core.ipynb", s6)
        @test occursin("abcd1234", s6)
    end

    @testset "NbDocs.build_symbol_index" begin
        cfg = temp_project([
            ("code", "#| default_exp core"),
            ("code", "#| export\nfoo(x) = x + 1"),
            ("code", "#| export\nstruct Bar\n    x::Int\nend"),
        ])
        Export.export_project(; cfg = cfg)
        idx = NbDocs.build_symbol_index(cfg)
        @test Set(keys(idx)) == Set(["foo", "Bar"])
        @test idx["foo"].src_file == "core.jl"
        @test idx["foo"].nb_file == "core.ipynb"
        @test !isempty(idx["foo"].cell_id)
        @test idx["Bar"].src_file == "core.jl"
    end

    @testset "NbDocs.explicitly_shown_names" begin
        nb = mk_nb([
            ("code", "show_doc(foo)"),
            ("code", "show_doc(:bar)"),
            ("code", "show_doc(\"baz\")"),
            ("code", "NBJulia.show_doc(qux)"),  # qualified form: not recognized (documented simplification)
            ("code", "x = 1"),
            ("markdown", "# hi"),
        ])
        shown = NbDocs.explicitly_shown_names(nb)
        @test shown == Set(["foo", "bar", "baz"])
    end

    @testset "NbDocs.plan_cell" begin
        already = Set{String}()
        plain = NbDocs.plan_cell(mk_cell("code", "x = 1"), already)
        @test plain.visible && plain.show_source && !plain.fold && isempty(plain.auto_names)

        exp = NbDocs.plan_cell(mk_cell("code", "#| export\nfoo(x) = x + 1"), already)
        @test exp.visible && !exp.show_source && !exp.fold
        @test exp.auto_names == ["foo"]
        @test "foo" in already  # already_documented set gets extended

        exports = NbDocs.plan_cell(mk_cell("code", "#| exports\nbar(x) = x + 1"), Set{String}())
        @test exports.visible && exports.show_source && exports.fold
        @test exports.auto_names == ["bar"]

        exporti = NbDocs.plan_cell(mk_cell("code", "#| exporti\n_helper() = 1"), Set{String}())
        @test exporti.visible && !exporti.show_source
        @test isempty(exporti.auto_names)  # private — no doc card

        hidden_export = NbDocs.plan_cell(mk_cell("code", "#| hide\n#| export\nfoo() = 1"), Set{String}())
        @test !hidden_export.visible
        @test isempty(hidden_export.auto_names)  # hidden wins — nbdev's own `_want_doc` excludes `hide` too

        defexp = NbDocs.plan_cell(mk_cell("code", "#| default_exp core"), Set{String}())
        @test defexp.visible && !defexp.show_source

        # a name already in `already_documented` (e.g. an explicit show_doc elsewhere) isn't re-auto-inserted
        pre = Set{String}(["foo"])
        dup = NbDocs.plan_cell(mk_cell("code", "#| export\nfoo(x) = x + 1"), pre)
        @test isempty(dup.auto_names)
    end

    @testset "NbDocs.is_silent_definition" begin
        silent(src) = NbDocs.is_silent_definition(first(Export.toplevel_exprs(src)))
        @test silent("function foo(x)\n x\nend")
        @test silent("foo(x) = x + 1")
        @test silent("struct Foo\n x::Int\nend")
        @test silent("abstract type Foo end")
        @test silent("macro foo(x)\n x\nend")
        @test silent("\"\"\"doc\"\"\"\nfoo(x) = x")
        @test !silent("x = 1")
        @test !silent("DEFAULT_TIMEOUT = 30")
        @test !silent("foo(1)")
        @test !silent("println(\"hi\")")

        # trailing `;` (parses to `:toplevel`) and a `begin...end` block:
        # silence is judged by the *last* real statement, same as what
        # Julia itself would actually evaluate to.
        @test silent("foo(x) = x + 1;")
        @test !silent("x = 42;")
        @test silent("begin\n y = 1\n foo(x) = x\nend")
        @test !silent("begin\n foo(x) = x\n y = 1\nend")
    end

    @testset "render_notebook: full pipeline in an isolated temp project" begin
        cfg = temp_project([
            ("markdown", "# core\n\n> description"),
            ("code", "#| default_exp core"),
            ("code", "#| export\nfoo(x) = x + 1"),
            ("code", "#| exports\nbar(x) = x + 2"),
            ("code", "DEFAULT_TIMEOUT = 30"),
            ("code", "#| hide\nx_hidden = 999"),
            ("code", "#| eval: false\nerror(\"must not run\")"),
        ])
        qmd = NbDocs.render_notebook(joinpath(cfg.d["nbs_path"], "core.ipynb"), cfg)

        @test occursin("# core", qmd)
        @test !occursin("foo(x) = x + 1", qmd)       # plain export: source hidden
        @test occursin("### `foo`", qmd)              # ...but still gets an auto show_doc card
        @test occursin("bar(x) = x + 2", qmd)          # exports: source shown
        @test occursin("code-fold", qmd)               # ...in a fold
        @test occursin("### `bar`", qmd)
        @test occursin("30", qmd)                       # plain assignment's value is shown
        @test !occursin("999", qmd)                     # hidden cell: nothing from it appears
        # #| eval: false means "show the code, but don't run it" (same as nbdev/Quarto's own
        # meaning) — so the source *does* still appear, just with no execution/output/callout:
        @test occursin("must not run", qmd)             # the source itself is shown...
        @test !occursin("callout-warning", qmd)          # ...but it never actually ran

        # a function-definition cell shouldn't *also* echo its own bare return value
        # (Julia's `foo(x)=...` evaluates to the function object, unlike Python's `def`) —
        # check the literal echo text, not "generic function" bare, since show_doc's own
        # "no docstring found" fallback legitimately contains that phrase too.
        @test !occursin("(generic function with", qmd)
    end

    @testset "render_notebook: explicit show_doc suppresses auto-insertion" begin
        cfg = temp_project([
            ("code", "#| hide\nusing NBJulia"),
            ("code", "#| default_exp core"),
            ("code", "#| export\nfoo(x) = x + 1"),
            ("code", "show_doc(foo)"),
        ])
        qmd = NbDocs.render_notebook(joinpath(cfg.d["nbs_path"], "core.ipynb"), cfg)
        @test count("### `foo`", qmd) == 1  # not duplicated
    end

    @testset "render_notebook: a cell error produces a callout and rendering continues" begin
        cfg = temp_project([
            ("code", "#| default_exp core"),
            ("code", "error(\"boom\")"),
            ("code", "y = 42"),
        ])
        qmd = NbDocs.render_notebook(joinpath(cfg.d["nbs_path"], "core.ipynb"), cfg)
        @test occursin("callout-warning", qmd)
        @test occursin("boom", qmd)
        @test occursin("42", qmd)  # the cell *after* the error still rendered
    end

    @testset "render_notebook: #| notest is skipped, matching test_nb — not run (and not blown up on) during docs rendering" begin
        cfg = temp_project([
            ("code", "#| default_exp core"),
            ("code", "#|notest\nerror(\"should never run during docs rendering either\")"),
            ("code", "y = 42"),
        ])
        nbpath = joinpath(cfg.d["nbs_path"], "core.ipynb")
        # test_nb already correctly skips this cell (pre-existing behavior) —
        # confirm render_notebook now does too, instead of running it and
        # leaking the error into the rendered docs.
        passed, _, _ = NbTest.test_nb(nbpath)
        @test passed
        qmd = NbDocs.render_notebook(nbpath, cfg)
        @test !occursin("callout-warning", qmd) # not executed, so no error callout — the real signal
        @test occursin("42", qmd)
    end

    @testset "NbQuarto.stage_docs" begin
        cfg = temp_project([
            ("markdown", "# core\n\n> description"),
            ("code", "#| default_exp core"),
            ("code", "#| export\nfoo(x) = x + 1"),
        ])
        stage = NbQuarto.stage_docs(cfg)
        @test isdir(stage)
        @test isfile(joinpath(stage, "core.qmd"))
        @test isfile(joinpath(stage, "_quarto.yml"))

        qmd = read(joinpath(stage, "core.qmd"), String)
        @test occursin("# core", qmd)
        @test occursin("### `foo`", qmd)

        yml = read(joinpath(stage, "_quarto.yml"), String)
        @test occursin("type: website", yml)
        @test occursin("enabled: false", yml)
        @test occursin("TestPkg", yml)
        # output-dir must point at cfg.doc_path, relative to the staging dir
        @test occursin(relpath(cfg.d["doc_path"], stage), yml)

        # re-staging the *same* project wipes a now-removed notebook's stale .qmd
        # instead of leaving it behind from a previous stage_docs call.
        NbIO.write_nb(
            mk_nb([("code", "#| default_exp extra"), ("code", "#| export\nbaz() = 1")]),
            joinpath(cfg.root, "nbs", "extra.ipynb"),
        )
        stage_b = NbQuarto.stage_docs(cfg)
        @test isfile(joinpath(stage_b, "extra.qmd"))
        rm(joinpath(cfg.root, "nbs", "extra.ipynb"))
        stage_c = NbQuarto.stage_docs(cfg)
        @test !isfile(joinpath(stage_c, "extra.qmd"))
        @test isfile(joinpath(stage_c, "core.qmd"))
    end

    @testset "NbQuarto.render_docs: real end-to-end quarto render" begin
        cfg = temp_project([
            ("markdown", "# core\n\n> description"),
            ("code", "#| default_exp core"),
            ("code", "#| export\nfoo(x) = x + 1"),
        ])
        @test Sys.which("quarto") !== nothing  # this machine has it; skip-worthy elsewhere
        ok = NbQuarto.render_docs(cfg)
        @test ok
        @test isfile(joinpath(cfg.d["doc_path"], "core.html"))
        html = read(joinpath(cfg.d["doc_path"], "core.html"), String)
        @test occursin("foo", html)
    end

    @testset "NbClean.clean_notebook" begin
        cell = mk_cell("code", "x = 1")
        cell["execution_count"] = 5
        cell["metadata"] = OrderedDict{String,Any}(
            "collapsed" => true,
            "nbdev" => OrderedDict{String,Any}("hide" => ""),
        )
        cell["outputs"] = Any[OrderedDict{String,Any}(
            "output_type" => "execute_result",
            "execution_count" => 5,
            "data" => OrderedDict{String,Any}("text/plain" => "Ptr{Nothing} @0x00007f1234abcd"),
        )]
        nb = NbIO.new_notebook([cell])
        nb["metadata"]["language_info"] = OrderedDict{String,Any}("name" => "julia")

        cleaned = NbClean.clean_notebook(nb)
        c = cleaned["cells"][1]
        @test c["execution_count"] === nothing
        @test c["id"] == "cell-0"                       # clean_ids=true default: deterministic position-based id
        @test haskey(c["metadata"], "nbdev")             # kept: directives can live here (NbIO.cell_directives)
        @test !haskey(c["metadata"], "collapsed")        # Jupyter UI noise: dropped
        @test !haskey(cleaned["metadata"], "language_info")
        @test c["outputs"][1]["data"]["text/plain"] == "Ptr{Nothing} @0x..."
        @test c["outputs"][1]["execution_count"] === nothing

        # original notebook untouched (pure function)
        @test nb["cells"][1]["execution_count"] == 5

        # clear_all=true drops outputs entirely instead of just de-noising them
        all_cleared = NbClean.clean_notebook(nb; clear_all = true)
        @test isempty(all_cleared["cells"][1]["outputs"])

        # clean_ids=false leaves an existing id alone
        kept_id = NbClean.clean_notebook(nb; clean_ids = false)
        @test kept_id["cells"][1]["id"] == cell["id"]
    end

    @testset "NbClean.clean_nb / clean_project: on-disk round trip, no-op when already clean" begin
        cfg = temp_project([("code", "#| default_exp core"), ("code", "#| export\nfoo(x) = x")])
        nbpath = joinpath(cfg.root, "nbs", "core.ipynb")
        before = read(nbpath, String)
        @test occursin(r"\"id\": \"[0-9a-f]{8}\"", before) # random hex id from mk_cell, not yet cleaned

        NbClean.clean_nb(nbpath; clear_all = cfg.d["clear_all"], clean_ids = cfg.d["clean_ids"])
        after = read(nbpath, String)
        @test occursin("\"id\": \"cell-0\"", after)
        @test after != before

        NbClean.clean_nb(nbpath; clear_all = cfg.d["clear_all"], clean_ids = cfg.d["clean_ids"])
        @test read(nbpath, String) == after # idempotent: cleaning an already-clean notebook changes nothing

        NbIO.write_nb(
            mk_nb([("code", "#| default_exp extra"), ("code", "#| export\nbar() = 1")]),
            joinpath(cfg.root, "nbs", "extra.ipynb"),
        )
        NbClean.clean_project(; cfg = cfg)
        @test occursin("cell-0", read(joinpath(cfg.root, "nbs", "extra.ipynb"), String))
    end

    @testset "NbClean.clean_filter_main: stdin/stdout entry point used by the git clean filter" begin
        cfg = temp_project([("code", "#| default_exp core"), ("code", "#| export\nfoo(x) = x")])
        raw = read(joinpath(cfg.root, "nbs", "core.ipynb"), String)
        cd(cfg.root) do
            io_in = IOBuffer(raw)
            io_out = IOBuffer()
            NbClean.clean_filter_main(; io_in = io_in, io_out = io_out)
            out = String(take!(io_out))
            @test occursin("\"id\": \"cell-0\"", out)
            @test occursin("\"execution_count\": null", out)
        end
    end

    @testset "NbGit.merge_cells: pure 3-way cell-id merge policy" begin
        base = mk_nb([("code", "x = 1"), ("code", "y = 2")])
        base_ids = [c["id"] for c in base["cells"]]
        id_a, id_b = base_ids[1], base_ids[2]

        mknb(pairs...) = OrderedDict{String,Any}(
            "cells" => Any[mk_cell_with_id(t, s, id) for (t, s, id) in pairs],
            "metadata" => OrderedDict{String,Any}(),
            "nbformat" => 4, "nbformat_minor" => 5,
        )

        # unchanged on both sides -> kept as-is
        ours = mknb(("code", "x = 1", id_a), ("code", "y = 2", id_b))
        theirs = mknb(("code", "x = 1", id_a), ("code", "y = 2", id_b))
        merged, conflict = NbGit.merge_cells(base, ours, theirs)
        @test !conflict
        @test [NbIO.cell_source(c) for c in merged["cells"]] == ["x = 1", "y = 2"]

        # only ours changed cell a -> ours wins, no conflict
        ours = mknb(("code", "x = 100", id_a), ("code", "y = 2", id_b))
        theirs = mknb(("code", "x = 1", id_a), ("code", "y = 2", id_b))
        merged, conflict = NbGit.merge_cells(base, ours, theirs)
        @test !conflict
        @test NbIO.cell_source(merged["cells"][1]) == "x = 100"

        # only theirs changed cell a -> theirs wins, no conflict
        ours = mknb(("code", "x = 1", id_a), ("code", "y = 2", id_b))
        theirs = mknb(("code", "x = 999", id_a), ("code", "y = 2", id_b))
        merged, conflict = NbGit.merge_cells(base, ours, theirs)
        @test !conflict
        @test NbIO.cell_source(merged["cells"][1]) == "x = 999"

        # both sides changed cell a differently -> true conflict, both versions kept
        ours = mknb(("code", "x = 100", id_a), ("code", "y = 2", id_b))
        theirs = mknb(("code", "x = 999", id_a), ("code", "y = 2", id_b))
        merged, conflict = NbGit.merge_cells(base, ours, theirs)
        @test conflict
        sources = [NbIO.cell_source(c) for c in merged["cells"]]
        @test "x = 100" in sources && "x = 999" in sources
        @test "y = 2" in sources
        @test any(s -> s !== nothing && occursin("merge conflict", s), sources)
        # the two conflicting alternatives (same id_a on both sides, as
        # clean_ids' position-based renumbering would produce) must come out
        # with distinct ids — confirmed by 3 stress-test agents to otherwise
        # break the id-uniqueness invariant sync_project/build_symbol_index
        # rely on.
        conflict_cells = [c for c in merged["cells"] if NbIO.cell_source(c) in ("x = 100", "x = 999")]
        @test length(conflict_cells) == 2
        @test conflict_cells[1]["id"] != conflict_cells[2]["id"]
        @test conflict_cells[1]["id"] != id_a && conflict_cells[2]["id"] != id_a

        # ours added a new cell, theirs untouched -> addition kept, no conflict
        new_id = NbIO.new_cell_id()
        ours = mknb(("code", "x = 1", id_a), ("code", "y = 2", id_b), ("code", "z = 3", new_id))
        theirs = mknb(("code", "x = 1", id_a), ("code", "y = 2", id_b))
        merged, conflict = NbGit.merge_cells(base, ours, theirs)
        @test !conflict
        @test "z = 3" in [NbIO.cell_source(c) for c in merged["cells"]]

        # theirs cleanly deleted cell b (ours left it untouched) -> dropped, no conflict
        ours = mknb(("code", "x = 1", id_a), ("code", "y = 2", id_b))
        theirs = mknb(("code", "x = 1", id_a))
        merged, conflict = NbGit.merge_cells(base, ours, theirs)
        @test !conflict
        @test !("y = 2" in [NbIO.cell_source(c) for c in merged["cells"]])

        # ours edited cell b, theirs deleted it -> edit-vs-delete conflict, edit kept + flagged
        ours = mknb(("code", "x = 1", id_a), ("code", "y = 200", id_b))
        theirs = mknb(("code", "x = 1", id_a))
        merged, conflict = NbGit.merge_cells(base, ours, theirs)
        @test conflict
        @test "y = 200" in [NbIO.cell_source(c) for c in merged["cells"]]
    end

    @testset "NbGit.flatten_nb: diff driver's outputs-ignored cell-source text view" begin
        cfg = temp_project([("code", "#| default_exp core"), ("code", "#| export\nfoo(x) = x")])
        nbpath = joinpath(cfg.root, "nbs", "core.ipynb")
        text = NbGit.flatten_nb(nbpath)
        @test occursin("foo(x) = x", text)
        @test occursin("[code]", text)
        @test NbGit.flatten_nb("/dev/null") == ""
    end

    @testset "NbGit: real end-to-end git integration (install_hooks, clean filter, merge, diff)" begin
        @test Sys.which("git") !== nothing  # this machine has it; skip-worthy elsewhere
        root = mktempdir()
        write(joinpath(root, "Project.toml"), """
        name = "GitIntegrationTest"
        uuid = "00000000-0000-0000-0000-00000000f00d"
        version = "0.1.0"

        [nbjulia]
        nbs_path = "nbs"
        """)
        mkpath(joinpath(root, "nbs"))
        run(`git -C $root init -q -b main`)
        run(`git -C $root config user.email test@test.com`)
        run(`git -C $root config user.name test`)
        cfg = Config.load_config(root)

        NbGit.install_hooks(; cfg = cfg)
        attrs = read(joinpath(root, ".gitattributes"), String)
        @test occursin("filter=nbjulia-clean", attrs)
        @test occursin("merge=nbjulia-notebook", attrs)
        @test occursin("diff=nbjulia-notebook", attrs)
        # idempotent: calling again doesn't duplicate attribute lines
        NbGit.install_hooks(; cfg = cfg)
        @test count("filter=nbjulia-clean", read(joinpath(root, ".gitattributes"), String)) == 1
        @test occursin("NBJulia.clean_filter_main", read(`git -C $root config filter.nbjulia-clean.clean`, String))
        @test occursin("NBJulia.merge_driver_main", read(`git -C $root config merge.nbjulia-notebook.driver`, String))
        @test occursin("NBJulia.diff_driver_main", read(`git -C $root config diff.nbjulia-notebook.command`, String))

        NbIO.write_nb(mk_nb([("code", "x = 1")]), joinpath(root, "nbs", "core.ipynb"))
        run(`git -C $root add -A`)
        run(`git -C $root commit -q -m base`)
        # the clean filter ran on `git add`: committed blob's id was normalized
        committed = read(`git -C $root show HEAD:nbs/core.ipynb`, String)
        @test occursin("\"id\": \"cell-0\"", committed)

        # a real conflicting merge: resolved as two labeled cells, exit code 1
        run(`git -C $root checkout -q -b ours-branch`)
        NbIO.write_nb(mk_nb([("code", "x = 100  # ours")]), joinpath(root, "nbs", "core.ipynb"))
        run(`git -C $root commit -q -am ours-change`)
        run(`git -C $root checkout -q main`)
        run(`git -C $root checkout -q -b theirs-branch`)
        NbIO.write_nb(mk_nb([("code", "x = 999  # theirs")]), joinpath(root, "nbs", "core.ipynb"))
        run(`git -C $root commit -q -am theirs-change`)
        run(`git -C $root checkout -q ours-branch`)
        st = run(ignorestatus(`git -C $root merge theirs-branch`))
        @test st.exitcode != 0
        result = read(joinpath(root, "nbs", "core.ipynb"), String)
        @test occursin("x = 100  # ours", result)
        @test occursin("x = 999  # theirs", result)
        @test occursin("merge conflict", result)
        run(`git -C $root merge --abort`) # leave the repo in a clean state before continuing

        # the diff driver engages for a plain working-tree `git diff`
        run(`git -C $root checkout -q main`)
        NbIO.write_nb(mk_nb([("code", "x = 42  # changed")]), joinpath(root, "nbs", "core.ipynb"))
        diffout = read(`git -C $root diff -- nbs/core.ipynb`, String)
        @test occursin("x = 42  # changed", diffout)
        @test !occursin("\"cell_type\"", diffout) # flattened view, not raw JSON
    end

    @testset "NbSync.parse_provenance_blocks: matches clean_ids' \"cell-N\" format, not just hex ids" begin
        @test NbSync.parse_provenance_blocks("# %% ../nbs/x.ipynb #60b40df5\nfoo()=1\n") ==
              [("../nbs/x.ipynb", "60b40df5", "foo()=1")]
        @test NbSync.parse_provenance_blocks("# %% ../nbs/x.ipynb #cell-5\nfoo()=1\n") ==
              [("../nbs/x.ipynb", "cell-5", "foo()=1")]
    end

    @testset "NbSync.sync_project: still works after clean_project has renumbered cell ids to cell-N" begin
        cfg = temp_project([("code", "#| default_exp core"), ("code", "#| export\nfoo(x) = x")])
        Export.export_project(; cfg = cfg)
        NbClean.clean_project(; cfg = cfg) # renumbers ids to cell-0, cell-1, ... (the default clean_ids=true)
        Export.export_project(; cfg = cfg) # re-export so the generated file's provenance headers use the new ids

        genfile = joinpath(cfg.d["src_path"], "core.jl")
        @test occursin(r"#cell-\d+", read(genfile, String))
        write(genfile, replace(read(genfile, String), "foo(x) = x" => "foo(x) = x * 2  # hand-edited"))

        result = NbSync.sync_project(; cfg = cfg)
        @test length(result.updated) == 1
        nb = NbIO.read_nb(joinpath(cfg.root, "nbs", "core.ipynb"))
        @test any(c -> occursin("x * 2  # hand-edited", something(NbIO.cell_source(c), "")), nb["cells"])
    end

    @testset "NbSync.sync_project: hand-edits in the generated file round-trip back to the notebook" begin
        cfg = temp_project([
            ("code", "#| default_exp core"),
            ("code", "#| export\nfoo(x) = x + 1"),
            ("code", "#| exporti\nhelper() = 1"),
        ])
        Export.export_project(; cfg = cfg)
        genfile = joinpath(cfg.d["src_path"], "core.jl")
        txt = read(genfile, String)
        txt = replace(txt, "foo(x) = x + 1" => "foo(x) = x + 100  # hand-edited")
        write(genfile, txt)

        result = NbSync.sync_project(; cfg = cfg)
        @test length(result.updated) == 1

        nb = NbIO.read_nb(joinpath(cfg.root, "nbs", "core.ipynb"))
        srcs = [NbIO.cell_source(c) for c in nb["cells"]]
        @test any(s -> occursin("foo(x) = x + 100  # hand-edited", s), srcs)
        @test any(s -> startswith(s, "#| export\n"), srcs) # directive line preserved verbatim
        @test any(s -> occursin("helper() = 1", s), srcs)  # untouched cell left alone

        # idempotent: nothing left to sync once the notebook matches the file
        result2 = NbSync.sync_project(; cfg = cfg)
        @test isempty(result2.updated)
    end

    @testset "NbSync.sync_project: a block whose cell id no longer exists is skipped, not errored" begin
        cfg = temp_project([("code", "#| default_exp core"), ("code", "#| export\nfoo(x) = x")])
        Export.export_project(; cfg = cfg)
        genfile = joinpath(cfg.d["src_path"], "core.jl")
        write(genfile, read(genfile, String) * "\n# %% ../nbs/core.ipynb #deadbeef\nghost() = 1\n")
        result = NbSync.sync_project(; cfg = cfg)
        @test isempty(result.updated) # the real cell didn't change; the ghost block has no matching cell
    end

    @testset "NbRelease.bump_version: rewrites only the version line" begin
        cfg = temp_project([("code", "#| default_exp core")])
        before = read(joinpath(cfg.root, "Project.toml"), String)
        @test occursin("version = \"0.1.0\"", before)

        newver = NbRelease.bump_version(; cfg = cfg, level = :patch)
        @test newver == "0.1.1"
        after = read(joinpath(cfg.root, "Project.toml"), String)
        @test occursin("name = \"TestPkg\"", after)     # rest of the file untouched
        @test occursin("nbs_path = \"nbs\"", after)

        newver2 = NbRelease.bump_version(; cfg = Config.load_config(cfg.root), level = :minor)
        @test newver2 == "0.2.0"
        newver3 = NbRelease.bump_version(; cfg = Config.load_config(cfg.root), level = :major)
        @test newver3 == "1.0.0"

        @test_throws ErrorException NbRelease.bump_version(; cfg = cfg, level = :nonsense)
    end

    @testset "NbRelease.bump_version: tolerates scaffold's own \"X.Y.Z-DEV\" default version" begin
        # NBJulia.scaffold (via PkgTemplates) writes exactly this by default;
        # every one of the 10 independent stress-test agents hit this crash
        # on the very first `prep_release()`/`bump_version()` call.
        cfg = temp_project([("code", "#| default_exp core")])
        txt = read(joinpath(cfg.root, "Project.toml"), String)
        write(joinpath(cfg.root, "Project.toml"), replace(txt, "version = \"0.1.0\"" => "version = \"1.0.0-DEV\""))
        newver = NbRelease.bump_version(; cfg = Config.load_config(cfg.root), level = :patch)
        @test newver == "1.0.1" # the -DEV tag is correctly dropped, not carried forward
    end

    @testset "NbRelease.changelog: lists commit subjects, prepends on a second call" begin
        cfg = temp_project([("code", "#| default_exp core")])
        git_init!(cfg)
        run(`git -C $(cfg.root) commit -q --allow-empty -m "add a feature"`)

        path = NbRelease.changelog(; cfg = cfg)
        text = read(path, String)
        @test occursin("## v0.1.0", text)
        @test occursin("- initial commit", text)
        @test occursin("- add a feature", text)

        NbRelease.bump_version(; cfg = Config.load_config(cfg.root), level = :patch)
        run(`git -C $(cfg.root) commit -q --allow-empty -m "another change"`)
        NbRelease.changelog(; cfg = Config.load_config(cfg.root))
        text2 = read(path, String)
        @test occursin("## v0.1.1", text2)
        @test findfirst("## v0.1.1", text2).start < findfirst("## v0.1.0", text2).start # newest section on top
    end

    @testset "NbRelease.changelog: falls back to the last Release commit (not full history) when there's no git tag" begin
        # prep_release deliberately never tags, so without this fix every
        # changelog call after the first would re-list the entire repo
        # history (confirmed by 4 stress-test agents) — scoping to "since
        # the last Release commit" instead fixes that without needing to
        # start tagging.
        cfg = temp_project([("code", "#| default_exp core")])
        git_init!(cfg)
        NbRelease.bump_version(; cfg = Config.load_config(cfg.root), level = :patch)
        NbRelease.changelog(; cfg = Config.load_config(cfg.root))
        run(`git -C $(cfg.root) add -A`)
        run(`git -C $(cfg.root) commit -q -m "Release v0.1.1"`)
        run(`git -C $(cfg.root) commit -q --allow-empty -m "a later change"`)

        NbRelease.bump_version(; cfg = Config.load_config(cfg.root), level = :patch)
        path = NbRelease.changelog(; cfg = Config.load_config(cfg.root))
        text = read(path, String)
        idx_new = findfirst("## v0.1.2", text).start
        idx_old = findfirst("## v0.1.1", text).start
        new_section = text[idx_new:(idx_old - 1)]
        @test occursin("a later change", new_section)
        @test !occursin("Release v0.1.1", new_section)  # the boundary commit itself is excluded
        @test !occursin("initial commit", new_section)  # and definitely not the whole prior history
    end

    @testset "NbRelease.prep_release: full export+test+bump+changelog+commit cycle" begin
        cfg = temp_project([("code", "#| default_exp core"), ("code", "#| export\nfoo() = 1")])
        git_init!(cfg)

        newver = NbRelease.prep_release(; cfg = Config.load_config(cfg.root), level = :minor)
        @test newver == "0.2.0"
        @test occursin("version = \"0.2.0\"", read(joinpath(cfg.root, "Project.toml"), String))
        @test isfile(joinpath(cfg.root, "CHANGELOG.md"))
        @test isfile(joinpath(cfg.d["src_path"], "core.jl")) # export_project ran as part of prep_release

        log = read(`git -C $(cfg.root) log --oneline`, String)
        @test occursin("Release v0.2.0", log)
        status = read(`git -C $(cfg.root) status --short`, String)
        @test isempty(strip(status)) # nothing left uncommitted
    end

    @testset "NbRelease.prep_release: aborts (no bump, no commit) if a notebook fails testing" begin
        cfg = temp_project([
            ("code", "#| default_exp core"),
            ("code", "#| export\nfoo() = 1"),
            ("code", "@assert 1 == 2"),
        ])
        git_init!(cfg)
        before = read(joinpath(cfg.root, "Project.toml"), String)

        @test_throws ErrorException NbRelease.prep_release(; cfg = Config.load_config(cfg.root))
        @test read(joinpath(cfg.root, "Project.toml"), String) == before
        @test !isfile(joinpath(cfg.root, "CHANGELOG.md"))
        log = read(`git -C $(cfg.root) log --oneline`, String)
        @test !occursin("Release", log)
    end

    @testset "NbRelease.prep_release: calling it twice with no new commits errors instead of double-releasing" begin
        cfg = temp_project([("code", "#| default_exp core"), ("code", "#| export\nfoo() = 1")])
        git_init!(cfg)
        v1 = NbRelease.prep_release(; cfg = Config.load_config(cfg.root), level = :patch)
        @test v1 == "0.1.1"

        @test_throws ErrorException NbRelease.prep_release(; cfg = Config.load_config(cfg.root), level = :patch)
        # the aborted second attempt changed nothing: no second bump, no duplicated changelog section
        @test occursin("version = \"0.1.1\"", read(joinpath(cfg.root, "Project.toml"), String))
        @test !occursin("version = \"0.1.2\"", read(joinpath(cfg.root, "Project.toml"), String))
        changelog_text = read(joinpath(cfg.root, "CHANGELOG.md"), String)
        @test count("## v0.1.1", changelog_text) == 1
    end

    @testset "real project smoke test: using NBJulia itself exports foo" begin
        # NBJulia's own nbs/00_core.ipynb exports `foo`; confirm the generated
        # src/core.jl round-trips through the actual package namespace.
        @test isdefined(NBJulia, :foo)
        @test NBJulia.foo() === nothing
    end
end
