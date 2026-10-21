"""
The cell-processor pipeline: the Julia analog of nbdev's `process.py`
(`NBProcessor`/`Processor`). Everything nbdev does — export, test-cell
selection, docs rendering — is a `Processor` run over a notebook's cells by
an `NBProcessor`.

A concrete `Processor` subtype can implement any mix of:
- `proc_begin!(p)` / `proc_end!(p)`: lifecycle hooks (defaults: no-op).
- `handlers(p)`: a `Dict{String,Function}` of `directive_name => f(cell, args...)`,
  dispatched once per matching directive present on a code cell (nbdev's
  `_<directive>_` method convention).
- `on_cell!(p, cell)`: runs unconditionally on every cell, any type (nbdev's
  generic `__call__`/bare-function processors like `strip_ansi`).

A cell is "hidden" (removed after this processor's pass) by setting its
`source` to `nothing`; `NbIO.cell_source` and friends already treat that as
"no source" rather than erroring.
"""
module Process

export Processor, NBProcessor, process!, proc_begin!, proc_end!, on_cell!, handlers

using ..NbIO

abstract type Processor end

proc_begin!(::Processor) = nothing
proc_end!(::Processor) = nothing
on_cell!(::Processor, cell) = nothing
handlers(::Processor) = Dict{String,Function}()

struct NBProcessor
    nb::Any
    procs::Vector{Processor}
end

NBProcessor(nb, p::Processor) = NBProcessor(nb, Processor[p])
NBProcessor(nb, procs::AbstractVector{<:Processor}) = NBProcessor(nb, Processor[procs...])
NBProcessor(nb, procs::Processor...) = NBProcessor(nb, Processor[procs...])

function process_cell!(p::Processor, cell)
    NbIO.cell_source(cell) === nothing && return nothing
    if get(cell, "cell_type", "") == "code"
        dirs = NbIO.cell_directives(cell)
        if !isempty(dirs)
            hs = handlers(p)
            for (name, argstr) in dirs
                f = get(hs, name, nothing)
                f === nothing && continue
                args = isempty(argstr) ? String[] : split(argstr)
                f(cell, args...)
            end
        end
    end
    on_cell!(p, cell)
    return nothing
end

function run_proc!(p::Processor, nb)
    proc_begin!(p)
    for cell in nb["cells"]
        process_cell!(p, cell)
    end
    proc_end!(p)
    filter!(c -> NbIO.cell_source(c) !== nothing, nb["cells"])
    return nothing
end

"""
    process!(np::NBProcessor)

Run every processor in `np.procs`, in order, over `np.nb`'s cells
(mutating it in place), dropping any cell whose source ended up `nothing`
after each processor's full pass. Returns the (mutated) notebook.
"""
function process!(np::NBProcessor)
    for p in np.procs
        run_proc!(p, np.nb)
    end
    return np.nb
end

end # module Process
