@use "github.com/jkroso/URI.jl" URI
@use MacroTools: postwalk
@use LibGit2
@use Dates

expr(x::T) where T = begin
  fields = fieldnames(T)
  isempty(fields) && return literal(x)
  Expr(:call, expr(T), (expr(getfield(x, f)) for f in fields)...)
end

literal(x::Any) = x
literal(s::Symbol) = QuoteNode(s)

expr(x::Tuple) = Expr(:tuple, x...)
expr(x::Vector) = Expr(:vect, x...)
expr(x::NamedTuple) = Expr(:tuple, (Expr(:(=), k, expr(v)) for (k,v) in pairs(x))...)
expr(x::AbstractDict) = Expr(:call, expr(typeof(x)), (:($(expr(k))=>$(expr(v))) for (k,v) in x)...)
expr(x::Dict) = Expr(:call, Dict, (:($(expr(k))=>$(expr(v))) for (k,v) in x)...)
expr(x::Base.ImmutableDict) = Expr(:call, Base.ImmutableDict, (:($(expr(k))=>$(expr(v))) for (k,v) in x)...)
expr(T::DataType) = begin
  length(T.parameters) == 0 && return ref(T)
  Expr(:curly, ref(T), (expr(x) for x in T.parameters)...)
end
expr(T::UnionAll) = Expr(:where, expr(T.body), T.var.name)
expr(T::TypeVar) = T.name
expr(x::Dates.Date) = :($(expr(Dates.Date))($(Dates.year(x)), $(Dates.month(x)), $(Dates.day(x))))
expr(x::Dates.Time) = :($(expr(Dates.Time))($(Dates.hour(x)), $(Dates.minute(x)), $(Dates.second(x))))
expr(x::Dates.DateTime) = :($(expr(Dates.DateTime))($(Dates.year(x)),
                                                    $(Dates.month(x)),
                                                    $(Dates.day(x)),
                                                    $(Dates.hour(x)),
                                                    $(Dates.minute(x)),
                                                    $(Dates.second(x))))
expr(x::Set) = :(Set([$((expr(v) for v in x)...)]))
expr(x::Regex) = :($x)
expr(x::SubString) = string(x)
expr(x::Rational) = :($(expr(x.num))//$(expr(x.den)))
expr(x::Enum) = :($(expr(typeof(x)))($(Int(x))))
expr(x::UnitRange) = :($(expr(x.start)):$(expr(x.stop)))
expr(x::StepRange) = :($(expr(x.start)):$(expr(x.step)):$(expr(x.stop)))
expr(x::Char) = x
expr(v::VersionNumber) = Expr(:macrocall, Symbol("@v_str"), LineNumberNode(0), string(v))
expr(x::Base.ExprNode) = x

ref(T::DataType) = isdefined(Main, nameof(T)) ? nameof(T) : GlobalRef(parentmodule(T), nameof(T))
remove_globals(e) = postwalk(x->x isa GlobalRef ? x.name : x, e)
find_globals(e) = begin
  globals = Set{GlobalRef}()
  postwalk(e) do e
    e isa GlobalRef && push!(globals, e)
    e
  end
  globals
end

generate_import((;mod,name)::GlobalRef) = generate_import(mod, [name])
generate_import(mod, names) = begin
  isstdlib(mod) && return stdlib_import(mod, names)
  f = getfile(mod)
  m = match(r"(.+)/refs/(?<user>[^/]+)/(?<module>[^/]+)/(?<ref>[^/]+)/(?<file>.+)", f)
  if isnothing(m)
    startswith(f, "$(homedir())/.julia") && return pkg_import(mod, names)
    return kip_import(f, names)
  end
  base,user,repo,ref,file = m
  dir = joinpath(base, "repos", user, repo)
  gr = LibGit2.GitRepo(dir)
  url = URI(LibGit2.url(LibGit2.get(LibGit2.GitRemote, gr, "origin")))
  url = URI{Symbol("")}(path=url.path.parent * url.path.name[1:end-4] * file, host=url.host)
  kip_import(url, names)
end

stdlib_import(mod, names) = Expr(:import, Expr(:(:), Expr(:(.), nameof(mod)), (Expr(:(.), n) for n in names)...))
pkg_import(mod, names) = Expr(:macrocall, var"@use", Expr(:(:), Expr(:(.), nameof(mod)), (Expr(:(.), n) for n in names)...))
kip_import(f, names) = Expr(:macrocall, var"@use", string(f), names...)

isstdlib(m::Module) = m in (Base, Core) || string(nameof(m)) in Kip.stdlib

getfile(m::Module) = begin
  isnothing(pathof(m)) || return pathof(m)
  for (file, mod) in Kip.modules
    mod === m && return file
  end
end
