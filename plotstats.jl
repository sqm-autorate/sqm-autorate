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


@df dat plot(:times + :timens/1e9,:rxload,title="Bandwidth and Delay through time",xlab="time",ylab="Relative load",labels="DL Load",legend=:topright,xlim=xlimvals,ylim=(0,3),alpha=0.5)
@df dat plot!(:times + :timens/1e9,:txload,title="Bandwidth and Delay through time",xlab="time",ylab="Relative load",labels="UL Load",alpha=0.5)
@df dat plot!(:times + :timens/1e9, :deltadelaydown / 20,label="Down Delay (del/20ms)",alpha=0.5)
p1 = @df dat plot!(:times + :timens/1e9, :deltadelayup / 20,label="Up Delay (del/20ms)",alpha=0.5)

@df dat plot(:times + :timens/1e9,:dlrate,title="Bandwidth Setting",label="Download Rate",xlab="time",ylab="kbps",legend=:topright,xlim=xlimvals,ylim=(0,downmax))
p2 = @df dat plot!(:times + :timens/1e9,:uprate,title="Bandwidth Setting",label="Upload Rate",xlab="time",ylab="kbps")


hists = CSV.read(histfile,DataFrame)

p3 = density(hists.upspeed,group=hists.time,xlim=(0,upmax*1.25),title="Upload History Distribution",legend=true)
p4 = density(hists.downspeed,group=hists.time,xlim=(0,downmax*1.25),title="Download History Distribution",legend=true)

plot(p1,p2,layout=(2,1),size=(1000,1500))
savefig("timeseries.png")

anim = @animate for t in unique(hists.time)
    density(hists[hists.time .== t, "upspeed"],xlim=(0,upmax*1.25),title=@sprintf("Up speed t=%.2fhrs",t/3600))
end
gif(anim,"uphist.gif",fps=3)

anim = @animate for t in unique(hists.time)
    density(hists[hists.time .== t,"downspeed"],xlim=(0,downmax*1.25),title=@sprintf("Down speed t=%.2fhrs",t/3600))
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
