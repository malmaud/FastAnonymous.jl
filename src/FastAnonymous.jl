module FastAnonymous

import Base: call, map, map!, show

export @anon

# ast_p is a pointer to the AST stored as a field in the object itself.
# This has two purposes:
#   - it serves, along with the ast_hash, as a unique identifier to control dispatch
#   - we'll use it to fish out the actual AST from the stagedfunction, which
#     does not otherwise have access to values.
# argnames is a tuple holding the names of anonymous-function input arguments
# V is the number of environment variables stored in the object
abstract AbstractClosure{ast_p,ast_hash,argnames,V}


#### Functions that only depend on values that are supplied as arguments

# Having this type reduces the number of types we have to generate

immutable Fun{ast_p,ast_hash,argnames} <: AbstractClosure{ast_p,ast_hash,argnames,0}
    ast::Expr     # ast_p is a pointer to ast
end

Fun(ast, argnames::(Symbol...)) = Fun{pointer_from_objref(ast), hash(ast), argnames}(ast)

stagedfunction call{ast_p,ast_hash,argnames}(f::Fun{ast_p,ast_hash,argnames}, __X__...)
    n = length(__X__)
    if length(argnames) != n
        return :(error(f, " called with ", $n, " arguments"))
    end
    ast = unsafe_pointer_to_objref(ast_p)
    Expr(:block, Expr(:meta, :inline), [:($(argnames[i]) = __X__[$i]) for i = 1:n]..., ast)
end

show{ast_p,ast_hash,argnames}(io::IO, f::Fun{ast_p,ast_hash,argnames}) = showanon(io, ast_p, argnames)

function showanon(io, ast_p, argnames)
    ast = unsafe_pointer_to_objref(ast_p)
    print(io, '(')
    first = true
    for a in argnames
        if !first
            print(io, ',')
        end
        first=false
        print(io, a)
    end
    print(io, ") -> ")
    show(io, ast)
end

#### @anon

anon_usage() = error("Usage: f = @anon x -> x+a")

macro anon(ex)
    (isa(ex,Expr) && ex.head in (:function, :->)) || anon_usage()
    arglist = tupleargs(ex.args[1])
    body = ex.args[2]
    syms = nonarg_symbols(body, arglist)
    scopedbody = scopecalls(current_module(), body)
    qbody = Expr(:quote, scopedbody)
    if isempty(syms)
        return :(Fun($(esc(qbody)), $arglist))
    end
    symst = tuple(syms...)
    fields = map(x->Val{x}, symst)
    values = Expr(:tuple, [esc(v) for v in symst]...)
    :(closure($(esc(qbody)), $arglist, $fields, $values))
end

#### closure generates types as needed
# Note that these are "value" closures: they store the values at time of construction
# (Usual statements about reference objects, like arrays, apply)
stagedfunction closure{fieldnames,TT}(ex, argnames::(Symbol...), ::Type{fieldnames}, values::TT)
    N = length(fieldnames)
    length(values) == N || error("Number of values must match number of fields")
    typename = getclosure(fieldnames, values)
    :($typename(ex, argnames, values...))
end

function show{ast_p,ast_hash,argnames,N}(io::IO, c::AbstractClosure{ast_p,ast_hash,argnames,N})
    showanon(io, ast_p, argnames)
    print(io, "\nwith:")
    fieldnames = names(typeof(c))
    for i = 2:N+1
        print(io, "\n  ", fieldnames[i], ": ", getfield(c, i))
    end
end

getclosure(fieldnames, fieldtypes) = getclosure(map(popval, fieldnames), fieldtypes)
popval{T}(::Type{Val{T}}) = T

function getclosure(fieldnames::(Symbol...), fieldtypes)
    # Build the type
    typename = gensym("Closure")
    extype = :($typename{ast_p,ast_hash,argnames})
    M = length(fieldnames)
    fields = [Expr(:(::), fieldnames[i], fieldtypes[i]) for i = 1:M]
    unshift!(fields, :(ast::Expr))
    extypedef = Expr(:type, true, Expr(:(<:), extype, :(AbstractClosure{ast_p,ast_hash,argnames,$M})), Expr(:block, fields...))
    eval(extypedef)
    # Build the constructor
    exconstr = :($typename(ast,argnames,values...) = $typename{pointer_from_objref(ast),hash(ast),argnames}(ast,values...))
    eval(exconstr)
    # Overload call
    fieldassign = [:($(fieldnames[i]) = f.$(fieldnames[i])) for i = 1:M]
    excall = quote
        stagedfunction call{ast_p,ast_hash,argnames}(f::$extype, __X__...)
            n = length(__X__)
            N = length(argnames)
            if n != N
                return :(error(f, " called with ", $n, " arguments"))
            end
            ast = unsafe_pointer_to_objref(ast_p)
            Expr(:block,
                 Expr(:meta, :inline),
                 [:($(argnames[i]) = __X__[$i]) for i = 1:N]...,
                 $fieldassign...,
                 ast)
        end
    end
    eval(excall)
    typename
end

#### Utilities

nonarg_symbols(body, arglist) = nonarg_symbols!(Set{Symbol}(), body, arglist)

function nonarg_symbols!(s, ex::Expr, arglist)
    ex.head == :line && return s
    startarg = ex.head == :call ? 2 : 1
    for i = startarg:length(ex.args)
        nonarg_symbols!(s, ex.args[i], arglist)
    end
    s
end
function nonarg_symbols!(s, sym::Symbol, arglist)
    if !(sym in arglist)
        push!(s, sym)
    end
    s
end
nonarg_symbols!(s, a, arglist) = s

tupleargs(funcargs::Symbol) = (funcargs,)
function tupleargs(funcargs::Expr)
    funcargs.head == :tuple || anon_usage()
    for i = 1:length(funcargs.args)
        if !isa(funcargs.args[i], Symbol)
            anon_usage()
        end
    end
    tuple(funcargs.args...)
end
tupleargs(funcargs) = anon_usage()


scopecalls(mod, body) = scopecalls!(mod, deepcopy(body))

function scopecalls!(mod, ex::Expr)
    if ex.head == :call
        ex.args[1] = modscope(mod, ex.args[1])
        startarg = 2
    else
        startarg = 1
    end
    for i = startarg:length(ex.args)
        scopecalls!(mod, ex.args[i])
    end
    ex
end
scopecalls!(mod, arg) = arg

modscope(mod, sym::Symbol) = Expr(:., mod, QuoteNode(sym))
function modscope(mod, ex::Expr)
    ex.head == :quote && return modscope(mod, ex.args[1])
    ex.head == :. || error("unsupported expression ", ex)
    modscope(modscope(mod, ex.args[1]), ex.args[2])
end

end # module
