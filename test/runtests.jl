using NBJulia
using NBJulia: NbIO, Process, Export, Config, Scaffold, NbTest
using Test
using OrderedCollections

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
    end

    @testset "self-import guard (catches a real loader deadlock at export time instead)" begin
        parsed(src) = first(Meta.parse(src, 1))
        @test Export.imported_package_names(parsed("using MyLib")) == ["MyLib"]
        @test Export.imported_package_names(parsed("using MyLib: foo")) == ["MyLib"]
        @test Export.imported_package_names(parsed("using MyLib, Other")) == ["MyLib", "Other"]
        @test Export.imported_package_names(parsed("using .MyLib")) == []  # relative — not a self-import risk
        @test Export.imported_package_names(parsed("import MyLib")) == ["MyLib"]
        @test Export.imported_package_names(parsed("foo(x) = x")) == []

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

    @testset "export_project: index-style markdown-only notebook is silently skipped" begin
        cfg = temp_project([("markdown", "# TestPkg\n\n> a description")]; nbname = "index.ipynb")
        res = Export.export_project(; cfg = cfg)
        @test isempty(res.relfiles)
        @test isempty(res.exportnames)
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

    @testset "real project smoke test: using NBJulia itself exports foo" begin
        # NBJulia's own nbs/00_core.ipynb exports `foo`; confirm the generated
        # src/core.jl round-trips through the actual package namespace.
        @test isdefined(NBJulia, :foo)
        @test NBJulia.foo() === nothing
    end
end
