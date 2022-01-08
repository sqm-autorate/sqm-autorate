## Copyright (C) 2021  @dlakelan
## This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License version 3 as published by the Free Software Foundation at https://www.gnu.org/licenses/

using StatsPlots,Random,Distributions

vals = rand(Exponential(5.0),100)
vals[50] = 123.0
vals[20] = 60.0
vals2 = rand(Exponential(5.0),100) .+ 20
vals3 = rand(Exponential(5.0),200) .+ [i*.2 for i in 1:200]
vals4 = rand(Exponential(5.0),100)
vals5 = rand(Exponential(5.0),100) .+ 80.0
allvals = [vals; vals2; vals3; vals4; vals5]

ewma1 = zeros(1).+5
ewma2 = zeros(1).+5

fastfactor = exp(log(1-.5)/(2/.5))
slowfactor = exp(log(1-.5)/(135/.5))

for (i,v) in enumerate(allvals)
    push!(ewma1,ewma1[end] * fastfactor + (1-fastfactor) * v)
    push!(ewma2, min(ewma2[end] * slowfactor +(1.0 - slowfactor)*v, ewma1[end]))
end
plot(ewma1, title="Filtered and Unfiltered delays",legend=false)
plot!(ewma2)
a = plot!(allvals,alpha=.4)

plot(ewma1 .- ewma2,title="Fast - Slow",legend=false)
b=plot!([(0,15),(600,15)])
plot(a,b,layout=(2,1))
