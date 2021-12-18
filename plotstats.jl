using Pkg
Pkg.activate(".")
using CSV, StatsPlots, DataFrames

xlimvals = (0,10e3)

dat = CSV.read("sqm-autorate-2.csv",DataFrame)
dat.times = dat.times .- minimum(dat.times)
@df dat plot(:times + :timens/1e9,:rxload,title="Bandwidth and Delay through time",xlab="time",ylab="Relative load",labels="DL Load",legend=:topright,xlim=xlimvals,ylim=(0,3),alpha=0.5)
@df dat plot!(:times + :timens/1e9,:txload,title="Bandwidth and Delay through time",xlab="time",ylab="Relative load",labels="UL Load",alpha=0.5)
@df dat plot!(:times + :timens/1e9, :deltadelaydown / 20,label="Down Delay (del/20ms)",alpha=0.5)
p1 = @df dat plot!(:times + :timens/1e9, :deltadelayup / 20,label="Up Delay (del/20ms)",alpha=0.5)

@df dat plot(:times + :timens/1e9,:dlrate,title="Bandwidth Setting",label="Download Rate",xlab="time",ylab="kbps",legend=:topright,xlim=xlimvals)
p2 = @df dat plot!(:times + :timens/1e9,:uprate,title="Bandwidth Setting",label="Upload Rate",xlab="time",ylab="kbps")


hists = CSV.read("sqm-speedhist.csv",DataFrame)

p3 = density(hists.upspeed,group=hists.time,xlim=(0,6e4),title="Upload History Distribution",legend=false)
p4 = density(hists.downspeed,group=hists.time,xlim=(0,6e5),title="Download History Distribution",legend=false)

plot(p1,p2,p3,p4,layout=(4,1))
