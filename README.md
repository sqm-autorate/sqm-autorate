# CAKE with Adaptive Bandwidth - "autorate"

## About autorate
**autorate** is an algorithm that automatically adapts the
bandwidth settings for the CAKE Smart Queue Management (SQM) 
by measuring traffic load and RTT times.

**autorate** is designed to maximize the speed (and minimize latency)
of LTE and cable modem connections/ISPs
where the link speed varies with time.
It is not intended for use on connections that have a
stable, fixed bandwidth.

[CAKE](https://www.bufferbloat.net/projects/codel/wiki/Cake/) 
is an algorithm that manages the buffering of data
being sent/received by an OpenWrt router so that no more
data is queued than is necessary,
minimizing the latency ("bufferbloat")
and improving the responsiveness of a network.

## Current Status

_sqm-autorate_, the current Lua-based test version, is undergoing heavy development.

If you wish to try out a "testable" version of _sqm-autorate_,
check out the `testing/lua-threads` branch.
Read the [README.md](https://github.com/Fail-Safe/sqm-autorate/tree/testing/lua-threads)
file for installation and testing details.

Although this branch seems to work, you should not assume that it is stable,
or that it will work well in your situation.
At this time, it might be prudent to avoid using _sqm-autorate_ during
mission-critical time periods (like your spouse's videoconference
or family Neflix time).

That said, we would like to hear your observations at:

* [Cake w/ Adaptive Bandwidth](https://forum.openwrt.org/t/cake-w-adaptive-bandwidth/108848/2265) topic on the OpenWrt Forum.
* [Github Discussions](https://github.com/Fail-Safe/sqm-autorate/discussions) on Github
* [Bug reports/issues](https://github.com/Fail-Safe/sqm-autorate/issues) on Github

_Note: The other branches in this repo are solely for the convenience of the developers.
There is no guarantee (or expectation) that they work at all._
