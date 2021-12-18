using Pkg
Pkg.activate(".")
using CSV, StatsPlots, DataFrames

xlimvals = (3500,5500)

dat = CSV.read("sqm-autorate-2.csv",DataFrame)
dat.times = dat.times .- minimum(dat.times)
@df dat plot(:times + :timens/1e9,:rxload,title="Bandwidth and Delay through time",xlab="time",ylab="Relative load",labels="DL Load",legend=:topright,xlim=xlimvals,ylim=(0,3))
@df dat plot!(:times + :timens/1e9,:txload,title="Bandwidth and Delay through time",xlab="time",ylab="Relative load",labels="UL Load")
@df dat plot!(:times + :timens/1e9, :deltadelaydown / 20,label="Down Delay (del/20ms)")
p1 = @df dat plot!(:times + :timens/1e9, :deltadelayup / 20,label="Up Delay (del/20ms)")

@df dat plot(:times + :timens/1e9,:dlrate,title="Bandwidth Setting",label="Download Rate",xlab="time",ylab="kbps",legend=:topright,xlim=xlimvals)
p2 = @df dat plot!(:times + :timens/1e9,:uprate,title="Bandwidth Setting",label="Upload Rate",xlab="time",ylab="kbps")


hists = CSV.read("sqm-speedhist.csv",DataFrame)

p3 = density(hists.upspeed,group=hists.time,xlim=(0,1e5))

plot(p1,p2,p3,layout=(3,1))
