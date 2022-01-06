using StatsPlots,Random,Distributions

vals = rand(Exponential(5.0),100)
vals2 = rand(Exponential(5.0),100) .+ 15
vals3 = rand(Exponential(5.0),200) .+ [i*.2 for i in 1:200]
vals4 = rand(Exponential(5.0),100)
allvals = [vals; vals2; vals3; vals4]

ewma1 = zeros(1).+5
ewma2 = zeros(1).+5

fastfactor = exp(log(.8)/(2/.5))
slowfactor = exp(log(.5)/(135/.5))

for (i,v) in enumerate(allvals)
    push!(ewma1,ewma1[end] * fastfactor + (1-fastfactor) * v)
    push!(ewma2, min(ewma2[end] * slowfactor +(1.0 - slowfactor)*v, ewma1[end]))
end
plot(ewma1)
plot!(ewma2)
