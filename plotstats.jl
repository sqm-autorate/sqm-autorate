using Pkg
Pkg.activate(".")
using CSV, StatsPlots, DataFrames

dat = CSV.read("sqm-autorate.csv",DataFrame)
dat.times = dat.times .- minimum(dat.times)
@df dat plot(:times + :timens/1e9,:rxload,title="Bandwidth and Delay through time",xlab="time",ylab="Relative load",labels="DL Load",legend=:topright,xlim=(0,100))
@df dat plot!(:times + :timens/1e9,:txload,title="Bandwidth and Delay through time",xlab="time",ylab="Relative load",labels="UL Load")
@df dat plot!(:times + :timens/1e9, :deltadelaydown / 10,label="Down Delay (del/10ms)")
p1 = @df dat plot!(:times + :timens/1e9, :deltadelayup / 10,label="Up Delay (del/10ms)")

@df dat plot(:times + :timens/1e9,:dlrate,title="Bandwidth Setting",label="Download Rate",xlab="time",ylab="kbps",legend=:topright,xlim=(0,100))
p2 = @df dat plot!(:times + :timens/1e9,:uprate,title="Bandwidth Setting",label="Upload Rate",xlab="time",ylab="kbps")

plot(p1,p2,layout=(2,1))

