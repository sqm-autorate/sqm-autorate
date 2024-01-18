#   Copyright (C) 2022
#       Daniel Lakeland mailto:dlakelan@street-artists.org (github @dlakelan)
#   This Source Code Form is subject to the terms of the Mozilla Public
#   License, v. 2.0. If a copy of the MPL was not distributed with this
#   file, You can obtain one at https://mozilla.org/MPL/2.0/.
using Pkg
Pkg.activate(".")
using CSV, StatsPlots, DataFrames, Printf, StatsBase, Measures

ratefile = "sqm-autorate.csv"
histfile = "sqm-speedhist.csv"

dat = CSV.read(ratefile,DataFrame)
dat.times = dat.times .- minimum(dat.times)
xmax=maximum(dat.times)

xlimvals = (0,xmax*1.3)

downmax = maximum(dat.dlrate)
upmax = maximum(dat.uprate)


function plotts(dat,filename,xlimvals)

    pload = @df dat plot(:times + :timens/1e9,:rxload,title="Bandwidth Fractional utilization",xlab="time (s)",ylab="Relative load/delay",labels="DL Load",legend=:topright,xlim=xlimvals,ylim=(0,1.25))
    @df dat plot!(:times + :timens/1e9,:txload,xlab="time (s)",ylab="Relative load",labels="UL Load")

    pdel = @df dat plot(:times + :timens/1e9, :deltadelaydown,title="Delay through time", label="Down Delay",ylab="delay (ms)",xlim=(xlimvals))
    @df dat plot!(:times + :timens/1e9, :deltadelayup,label="Up Delay")

    pbw = @df dat plot(:times + :timens/1e9,:dlrate ./ 1000,title="Cake Bandwidth Setting",label="Download Rate (Mbps)",xlab="time (s)",ylab="Mbps",legend=:topright,xlim=xlimvals,ylim=(0,max(downmax,upmax)*1.2/1000.0))
    @df dat plot!(:times + :timens/1e9,:uprate ./ 1000,label="Upload Rate (Mbps)",xlab="time (s)",ylab="Mbps")

    plot(pload,pdel,pbw,layout=grid(3,1,heights=[.45,.1,.45]),size=(800,1200),left_margin=5mm)
    savefig(filename)
end
plotts(dat,filename) = plotts(dat,filename,xlimvals)
plotts(dat,"timeseries.png")

hists = CSV.read(histfile,DataFrame)

p3 = density(hists.upspeed ./ 1000,group=hists.time,xlim=(0,upmax*1.25/1000),title="Upload History Distribution",xlab="Bandwidth (Mbps)",legend=true)
p4 = density(hists.downspeed ./ 1000,group=hists.time,xlim=(0,downmax*1.25/1000),title="Download History Distribution",xlab="Bandwidth (Mbps)",legend=true)


anim = @animate for t in unique(hists.time)
    density(hists[hists.time .== t, "upspeed"] ./ 1000,xlim=(0,upmax*1.25/1000),xlab="Bandwidth (Mbps)",title=@sprintf("Up speed t=%.2fhrs",t/3600))
end
gif(anim,"uphist.gif",fps=3)

anim = @animate for t in unique(hists.time)
    density(hists[hists.time .== t,"downspeed"] ./ 1000,xlim=(0,downmax*1.25/1000),xlab="Bandwidth (Mbps)",title=@sprintf("Down speed t=%.2fhrs",t/3600))
end
gif(anim,"downhist.gif",fps=3)


relthr = 1.0-1.0/3600

ecdfdown = ecdf(dat.deltadelaydown)
ecdfup = ecdf(dat.deltadelayup)
downq = quantile(dat.deltadelaydown,relthr)
upq = quantile(dat.deltadelayup,relthr)

@df dat plot(ecdfdown,label=false,ylim=(.99,1),xlim=(0,50),
             title="Fraction of Down delay less than x",xlab="delay (ms)",ylab="Fraction")
plot!([0.0,50.0],[relthr,relthr],label="1 second per hour",legend=:bottomright)
plot!([downq,downq],[0.0,1.0],label=@sprintf("%.1f ms",downq))
savefig("delaydownecdf.png")

@df dat plot(ecdfup,label=false,ylim=(.99,1),xlim=(0,50),
             title="Fraction of Up delay less than x",xlab="delay (ms)",ylab="Fraction")
plot!([0.0,50.0],[relthr,relthr],label="1 second per hour",legend=:bottomright)
plot!([upq,upq],[0.0,1.0],label=@sprintf("%.1f ms",upq))
savefig("delayupecdf.png")


## plot a timeseries zoomed to a particular region:

plotts(dat,"zoomedts.png",(0,100))
