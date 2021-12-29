using Pkg
Pkg.activate(".")
using CSV, StatsPlots, DataFrames, Printf, StatsBase

ratefile = "sqm-autorate.csv"
histfile = "sqm-speedhist.csv"

dat = CSV.read(ratefile,DataFrame)
dat.times = dat.times .- minimum(dat.times)
xmax=maximum(dat.times)

xlimvals = (0,xmax*1.3)

downmax = maximum(dat.dlrate)
upmax = maximum(dat.uprate)


@df dat plot(:times + :timens/1e9,:rxload,title="Bandwidth and Delay through time",xlab="time (s)",ylab="Relative load/delay",labels="DL Load",legend=:topright,xlim=xlimvals,ylim=(0,3),alpha=0.5)
@df dat plot!(:times + :timens/1e9,:txload,title="Bandwidth and Delay through time",xlab="time (s)",ylab="Relative load/delay",labels="UL Load",alpha=0.5)
@df dat plot!(:times + :timens/1e9, :deltadelaydown / 20,label="Down Delay (del/20ms)",alpha=0.5)
p1 = @df dat plot!(:times + :timens/1e9, :deltadelayup / 20,label="Up Delay (del/20ms)",alpha=0.5)

@df dat plot(:times + :timens/1e9,:dlrate ./ 1000,title="Bandwidth Setting",label="Download Rate (Mbps)",xlab="time (s)",ylab="Mbps",legend=:topright,xlim=xlimvals,ylim=(0,downmax/1000.0))
p2 = @df dat plot!(:times + :timens/1e9,:uprate ./ 1000,title="Bandwidth Setting",label="Upload Rate (Mbps)",xlab="time (s)",ylab="Mbps")


hists = CSV.read(histfile,DataFrame)

p3 = density(hists.upspeed ./ 1000,group=hists.time,xlim=(0,upmax*1.25/1000),title="Upload History Distribution",xlab="Bandwidth (Mbps)",legend=true)
p4 = density(hists.downspeed ./ 1000,group=hists.time,xlim=(0,downmax*1.25/1000),title="Download History Distribution",xlab="Bandwidth (Mbps)",legend=true)

plot(p1,p2,layout=(2,1),size=(800,1200))
savefig("timeseries.png")

anim = @animate for t in unique(hists.time)
    density(hists[hists.time .== t, "upspeed"] ./ 1000,xlim=(0,upmax*1.25/1000),xlab="Bandwidth (Mbps)",title=@sprintf("Up speed t=%.2fhrs",t/3600))
end
gif(anim,"uphist.gif",fps=3)

anim = @animate for t in unique(hists.time)
    density(hists[hists.time .== t,"downspeed"] ./ 1000,xlim=(0,downmax*1.25/1000),xlab="Bandwidth (Mbps)",title=@sprintf("Down speed t=%.2fhrs",t/3600))
end
gif(anim,"downhist.gif",fps=3)


relthr = 1.0-1.0/3600
@df dat plot(ecdf(:deltadelaydown),label=false,ylim=(.99,1),xlim=(0,50),
             title="Fraction of Down delay less than x",xlab="delay (ms)",ylab="Fraction")
plot!([0.0,50.0],[relthr,relthr],label="1 second per hour",legend=:bottomright)
savefig("delaydownecdf.png")
@df dat plot(ecdf(:deltadelayup),label=false,ylim=(.99,1),xlim=(0,50),
             title="Fraction of Up delay less than x",xlab="delay (ms)",ylab="Fraction")
plot!([0.0,50.0],[relthr,relthr],label="1 second per hour",legend=:bottomright)
savefig("delayupecdf.png")
