using BenchmarkTools
using FLOWMath
using SingleFieldStructArrays

const paramsfile = joinpath(@__DIR__, "params.json")
const resultsfile = joinpath(@__DIR__, "results.json")

struct Foo3{T1,T2,T3}
    t::T1
    x::T2
    y::T3
end

function run_benchmarks(; load_params=true, save_params=false)
    n_cp = 51
    t = range(0.0, 1.0, length=n_cp)
    x = @. sin(2*pi*(t-0.2)) + 0.3*sin(4*pi*(t-0.3))
    y = @. 1.5*sin(2*pi*(t-0.5)) + 0.5*sin(4*pi*(t-0.2))
    foos = Foo3.(t, x, y)

    cache = Foo3(similar(t), similar(x), similar(y))

    n_out = 1001
    t_out = range(t[1], t[end], length=n_out)
    x_out = similar(t_out)
    y_out = similar(t_out)

    foos_out = Foo3.(t_out, x_out, y_out)

    suite = BenchmarkGroup()

    s_scalars = suite["struct_scalars"] = BenchmarkGroup()

    s_scalars["getproperty"] = @benchmarkable akima_getproperty($foos, $t_out)
    s_scalars["cache"] = @benchmarkable akima_cache($foos, $t_out, $cache)
    s_scalars["cache_loop"] = @benchmarkable akima_cache_loop($foos, $t_out, $cache)
    s_scalars["SingleFieldStructArray"] = @benchmarkable akima_sfsa($foos, $t_out)

    s_scalars["cache_loop_no_alloc!"] = @benchmarkable akima_cache_loop_no_alloc!($x_out, $y_out, $foos, $t_out, $cache)
    s_scalars["SingleFieldStructArray_no_alloc!"] = @benchmarkable akima_sfsa_no_alloc!($foos_out, $foos)

    if load_params && isfile(paramsfile)
        # Load the benchmark parameters.
        # https://github.com/JuliaCI/BenchmarkTools.jl/blob/master/doc/manual.md#caching-parameters
        loadparams!(suite, BenchmarkTools.load(paramsfile)[1])

        # Also need to warmup the benchmarks to get rid of the JIT overhead
        # (when not using tune!):
        # https://discourse.julialang.org/t/benchmarktools-theory-and-practice/5728
        warmup(suite, verbose=false)
    else
        tune!(suite, verbose=false)
    end

    results = run(suite, verbose=false)

    if save_params
        BenchmarkTools.save(paramsfile, params(suite))
    end

    return suite, results
end

# No SingleFieldStructArray, allocate inside the function.
function akima_getproperty(foos, t_out)
    t = getproperty.(foos, :t)
    x = getproperty.(foos, :x)
    y = getproperty.(foos, :y)

    x_out = akima(t, x, t_out)
    y_out = akima(t, y, t_out)

    return x_out, y_out
end

# No SingleFieldStructArray, use cache to avoid allocating inside the function.
function akima_cache(foos, t_out, cache)
    @. cache.t = getproperty(foos, :t)
    @. cache.x = getproperty(foos, :x)
    @. cache.y = getproperty(foos, :y)

    x_out = akima(cache.t, cache.x, t_out)
    y_out = akima(cache.t, cache.y, t_out)

    return x_out, y_out
end

# No SingleFieldStructArray, use cache to avoid allocating inside the function,
# and just do one loop.
function akima_cache_loop(foos, t_out, cache)
    for i in eachindex(foos)
        @inbounds cache.t[i] = foos[i].t
        @inbounds cache.x[i] = foos[i].x
        @inbounds cache.y[i] = foos[i].y
    end

    x_out = akima(cache.t, cache.x, t_out)
    y_out = akima(cache.t, cache.y, t_out)

    return x_out, y_out
end

# SingleFieldStructArray.
function akima_sfsa(foos, t_out)
    t = SingleFieldStructArray(foos, Val{:t})
    x = SingleFieldStructArray(foos, Val{:x})
    y = SingleFieldStructArray(foos, Val{:y})

    x_out = akima(t, x, t_out)
    y_out = akima(t, y, t_out)

    return x_out, y_out
end

# No SingleFieldStructArray, use cache to avoid allocating inside the function,
# and just do one loop. Mutating the outputs.
function akima_cache_loop_no_alloc!(x_out, y_out, foos, t_out, cache)
    for i in eachindex(foos)
        @inbounds cache.t[i] = foos[i].t
        @inbounds cache.x[i] = foos[i].x
        @inbounds cache.y[i] = foos[i].y
    end

    spline = Akima(cache.t, cache.x)
    x_out .= spline.(t_out)
    spline = Akima(cache.t, cache.y)
    y_out .= spline.(t_out)

    return nothing
end

# SingleFieldStructArray, mutating.
function akima_sfsa_no_alloc!(foos_out, foos)
    t = SingleFieldStructArray(foos, Val{:t})
    x = SingleFieldStructArray(foos, Val{:x})
    y = SingleFieldStructArray(foos, Val{:y})

    t_out = SingleFieldStructArray(foos_out, Val{:t})
    x_out = SingleFieldStructArray(foos_out, Val{:x})
    y_out = SingleFieldStructArray(foos_out, Val{:y})

    spline = Akima(t, x)
    x_out .= spline.(t_out)
    spline = Akima(t, y)
    y_out .= spline.(t_out)

    return nothing
end

function compare_benchmarks(; load_params=true, save_params=false, save_results=false)
    suite, results_new = run_benchmarks(load_params=load_params, save_params=save_params)

    # SingleFieldStructArrays vs getproperty, scalars:
    # BenchmarkTools.TrialJudgement:
    #   time:   -20.42% => improvement (5.00% tolerance)
    #   memory: -27.58% => improvement (1.00% tolerance)

    # SingleFieldStructArrays vs cache, scalars:
    # BenchmarkTools.TrialJudgement:
    #   time:   -20.27% => improvement (5.00% tolerance)
    #   memory: -23.97% => improvement (1.00% tolerance)

    # SingleFieldStructArrays vs cache with loop, scalars:
    # BenchmarkTools.TrialJudgement:
    #   time:   -15.31% => improvement (5.00% tolerance)
    #   memory: +0.93% => invariant (1.00% tolerance)

    # SingleFieldStructArrays mutating vs cache with loop mutating, scalars:
    # BenchmarkTools.TrialJudgement:
    #   time:   -26.98% => improvement (5.00% tolerance)
    #   memory: +6.35% => regression (1.00% tolerance)

    println("SingleFieldStructArrays vs getproperty, scalars:")
    rold = results_new["struct_scalars"]["getproperty"]
    rnew = results_new["struct_scalars"]["SingleFieldStructArray"]
    display(judge(median(rnew), median(rold)))

    println("SingleFieldStructArrays vs cache, scalars:")
    rold = results_new["struct_scalars"]["cache"]
    rnew = results_new["struct_scalars"]["SingleFieldStructArray"]
    display(judge(median(rnew), median(rold)))

    println("SingleFieldStructArrays vs cache with loop, scalars:")
    rold = results_new["struct_scalars"]["cache_loop"]
    rnew = results_new["struct_scalars"]["SingleFieldStructArray"]
    display(judge(median(rnew), median(rold)))

    println("SingleFieldStructArrays mutating vs cache with loop mutating, scalars:")
    rold = results_new["struct_scalars"]["cache_loop_no_alloc!"]
    rnew = results_new["struct_scalars"]["SingleFieldStructArray_no_alloc!"]
    display(judge(median(rnew), median(rold)))

    if isfile(resultsfile)
        results_old = BenchmarkTools.load(resultsfile)[1]

        println("SingleFieldStructArray current vs old, allocating output")
        rold = results_old["struct_scalars"]["SingleFieldStructArray"]
        rnew = results_new["struct_scalars"]["SingleFieldStructArray"]
        display(judge(median(rnew), median(rold)))

        println("SingleFieldStructArray current vs old, mutating output")
        rold = results_old["struct_scalars"]["SingleFieldStructArray_no_alloc!"]
        rnew = results_new["struct_scalars"]["SingleFieldStructArray_no_alloc!"]
        display(judge(median(rnew), median(rold)))
    end

    if save_results
        BenchmarkTools.save(resultsfile, results_new)
    end

    return suite, results_new
end

if !isinteractive()
    compare_benchmarks(; load_params=true, save_params=false, save_results=false)
end
