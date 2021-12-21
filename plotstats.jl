using Pkg
Pkg.activate(".")
using CSV, StatsPlots, DataFrames, Printf

ratefile = "sqm-autorate.csv"
histfile = "sqm-speedhist.csv"

dat = CSV.read(ratefile,DataFrame)
dat.times = dat.times .- minimum(dat.times)
xmax=maximum(dat.times)

xlimvals = (0,xmax*1.3)

@df dat plot(:times + :timens/1e9,:rxload,title="Bandwidth and Delay through time",xlab="time",ylab="Relative load",labels="DL Load",legend=:topright,xlim=xlimvals,ylim=(0,3),alpha=0.5)
@df dat plot!(:times + :timens/1e9,:txload,title="Bandwidth and Delay through time",xlab="time",ylab="Relative load",labels="UL Load",alpha=0.5)
@df dat plot!(:times + :timens/1e9, :deltadelaydown / 20,label="Down Delay (del/20ms)",alpha=0.5)
p1 = @df dat plot!(:times + :timens/1e9, :deltadelayup / 20,label="Up Delay (del/20ms)",alpha=0.5)

@df dat plot(:times + :timens/1e9,:dlrate,title="Bandwidth Setting",label="Download Rate",xlab="time",ylab="kbps",legend=:topright,xlim=xlimvals)
p2 = @df dat plot!(:times + :timens/1e9,:uprate,title="Bandwidth Setting",label="Upload Rate",xlab="time",ylab="kbps")


hists = CSV.read(histfile,DataFrame)

p3 = density(hists.upspeed,group=hists.time,xlim=(0,6e4),title="Upload History Distribution",legend=true)
p4 = density(hists.downspeed,group=hists.time,xlim=(0,6e5),title="Download History Distribution",legend=true)

plot(p1,p2,layout=(2,1),size=(1000,1500))
savefig("timeseries.png")

anim = @animate for t in unique(hists.time)
    density(hists[hists.time .== t, "upspeed"],xlim=(0,60e3),title=@sprintf("Up speed t=%.2fhrs",t/3600))
end
gif(anim,"uphist.gif",fps=3)

anim = @animate for t in unique(hists.time)
    density(hists[hists.time .== t,"downspeed"],xlim=(0,600e3),title="Down speed t=$t")
end
gif(anim,"downhist.gif",fps=3)
