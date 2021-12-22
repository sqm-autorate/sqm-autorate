# CAKE with Adaptive Bandwidth - "autorate"

## Lua Native Port

**sqm-autorate.lua** is a Lua native port of the original
[sqm-autorate.sh shell script.](https://github.com/lynxthecat/sqm-autorate)
Functionality should be virtually identical to the shell version, so refer to [Original Shell Version](#original-shell-version) (below) for details as to the goal and theory.

### Lua Port Setup

Run the following setup script to download the required operational files and prequisites:

```bash
sh -c "$(curl -sL https://raw.githubusercontent.com/Fail-Safe/sqm-autorate/experimental/sqm-autorate-setup.sh)"
```

### Configuration

Generally, configuration should be performed via the `/etc/config/sqm-autorate` file.

Advanced users may override values (following comments) directly in `/usr/lib/sqm-autorate/sqm-autorate.lua` as comfort level allows.

### Execution

The Lua port can be invoked directly or operate via the sqm-autorate service script in this branch.

#### Direct Execution (for Testing and Tuning)

For testing/tuning, invoke the `sqm-autorate.lua` script from the command line:

```bash
lua /usr/lib/sqm-autorate/sqm-autorate.lua
```

The script outputs statistics about various internal variables to the terminal.
When you run a speed test, you should see the `current_dl_rate` and
`current_ul_rate` values change to match the current conditions.
They should then drift back to the configured download and update rates
when the link is idle.

To disable the output, set `enable_lynx_graph_output` to "false" in the script.
The script also writes the similar information to `/tmp/sqm-autorate.csv` and speed history data to `/tmp/sqm-speedhist.csv`.
There is currently no way to turn off output to these files, though the file location can be modified via `/etc/config/sqm-autorate`.

#### Service Execution

You can also install the `sqm-autorate.lua` script as a service,
so that it starts up automatically when you reboot the router.

```bash
service sqm-autorate enable && service sqm-autorate start
```

There is a detailed and fun discussion with plenty of sketches relating to the development of the script and alternatives on the [OpenWrt Forum - CAKE /w Adaptive Bandwidth.](https://forum.openwrt.org/t/cake-w-adaptive-bandwidth/108848/312)

### A Request to Testers

If you use this script I have just one ask.
Please post your experience on this
[OpenWrt Forum thread.](https://forum.openwrt.org/t/cake-w-adaptive-bandwidth/108848/312)
Your feedback will help improve the script for the benefit of others.

## Original Shell Version

### Purpose

_The remainder of this document needs to be revised in view of the
new implementation (both the shell script and Lua code)
that use "setpoint" for single download and upload settings.
This algorithm continually samples the delay and RTT to
move the setpoint to maximize throughput and minimize latency._

**autorate.sh** is a script that automatically adapts
[CAKE Smart Queue Management (SQM)](https://www.bufferbloat.net/projects/codel/wiki/Cake/)
bandwidth settings by measuring traffic load and RTT times.
This is designed for variable bandwidth connections such as LTE,
and is not intended for use on connections that have a stable,
fixed bandwidth.

CAKE is an algorithm that manages the buffering of data being sent/received
by an [OpenWrt router](https://openwrt.org) so that no more data
is queued than is necessary, minimizing the latency ("bufferbloat")
and improving the responsiveness of a network.

The CAKE algorithm always uses fixed upload and download
bandwidth settings to manage its queues.
Variable bandwidth connections present a challenge
because the actual bandwidth at any given moment is not known.

People generally pick a compromise bandwidth setting,
but typically this means lost bandwidth in exchange
for latency control.
This compromise is hardly ideal:
if the compromise setting is too low,
the connection is unnecessarily throttled back
to the compromise setting (yellow);
if the setting is too high, CAKE will still buffer
too much data (green) and induce unwanted latency.

![image of Bandwidth Compromise](./Bandwidth-Compromise.png)

The **autorate.sh** script periodically measures the load
and Round-Trip-Time (RTT) to adjust the upload and
download values for the CAKE algorithm.

### Theory of Operation

The `autorate.sh` script runs regularly and
adjusts the bandwidth settings of the CAKE SQM algorithm
to reflect the current conditions on the bottleneck link.
(The script adjusts the upload and download settings independently each time it runs.)
The script is typically configured to run once per second
and make the following adjustments:

- When traffic is low, the bandwidth setting decays
toward a minimum configured value
- When traffic is high, the bandwidth setting is incrementally increased
until an RTT spike is detected or until the setting reaches the maximum configured value
- Upon detecting an RTT spike, the bandwidth setting is decreased

_**The remainder of this document has been deprecated - read the Setup section above**_

>  ### Parameters
>
> **Setting the minimum value:**
> Set the minimum value at, or slightly below,
> the lowest speed observed from the ISP during your testing.
> This setting will, in general, never result in
> bufferbloat even under the worst conditions.
> Under no load, the routine will adjust the bandwidth
> downwards towards that minimum.
>
> **Setting the maximum value:**
> The maximum bandwidth should be set to the lower
> of the maximum bandwidth that the ISP can provide
> or the maximum bandwidth required by the user.
> The script will adjust the bandwidth up when there is traffic,
> as long no RTT spike is detected.
> Setting this value to a maximum required level
> will have the advantage that the script will
> stay at that level during optimum conditions
> rather than always having to test whether the
> bandwidth can be increased (which necessarily
> results in allowing some excess latency).
>
> To elaborate on the above, a variable bandwidth
> connection may be most ideally divided up into
> a known fixed, stable component, on top of which
> is provided an unknown variable component:
>
> ![image of CAKE bandwidth adaptation](./CAKE-Bandwidth-Adaptation.png)
>
> The minimum bandwidth is then set to (or
> slightly below) the fixed component, and the
> maximum bandwidth may be set to (or slightly above)
> the maximum observed bandwidth.
> Or, if a lower maximum bandwidth is required
> by the user, the maximum bandwidth is set
> to that lower bandwidth as explained above.
>
>
> ### Required packages
>
> - **iputils-ping** for more advanced ping with sub 1s ping frequency
> - **coreutils-date** for accurate time keeping
> - **coreutils-sleep** for accurate sleeping
>
> ### Installation on OpenWrt
>
> - Install SQM (`luci-app-sqm`) and enable CAKE on the interface(s)
> as described in the
> [OpenWrt SQM documentation](https://openwrt.org/docs/guide-user/network/traffic-shaping/sqm)
> - [SSH into the router](https://openwrt.org/docs/guide-quick-start/sshadministration)
> - Run the following commands to place the script at `/root/autorate.sh`
> and make it executable:
>
>    ```bash
>    opkg update; opkg install iputils-ping coreutils-date coreutils-sleep
>    cd /root
>    wget https://raw.githubusercontent.com/lynxthecat/sqm-autorate/main/sqm-autorate.sh
>    chmod +x ./sqm-autorate.sh
>    ```
>
> - Edit the `sqm-autorate.sh` script using vi or nano to supply
> information about your router and your ISP's speeds.
> The minimum bandwidth should be set to at, or below,
> the lowest observed bandwidth, and the maximum bandwidth
> set to an estimate of the best possible bandwidth
> the connection can obtain.
> Rates are in kilobits/sec - enter "36000" for a 36 mbps link.
>
>   - Change `ul_if` and `dl_if` to match the names of the
> upload and download interfaces to which CAKE is applied
> These can be obtained, for example, by consulting the configured SQM settings
> in LuCi or by examining the output of `tc qdisc ls`.
>   - Set minimum bandwidth variables (`min_ul_rate` and `min_dl_rate` in the script)
> to the minimum bandwidth you expect.
>   - Set maximum bandwidth (`max_ul_rate` and `max_dl_rate`)
> to the maximum bandwidth you expect your connection could obtain from your ISP.
>   - Save the changes and exit the editor
>
> ### Manual testing
>
> - Run the modified `autorate.sh` script:
>
>    ```bash
>    ./sqm-autorate.sh
>    ```
>
> - Monitor the script output to see how it adjusts the download
> and upload rates as you use the connection.
> (You will see this output if `enable_verbose_output` is set to '1'.
> Set it to '0' if you no longer want the verbose logging.)
> - Press ^C to halt the process.
>
> ### Install as a service
>
> You can install this as a service that starts up the
> autorate process whenever the router reboots.
> To do this:
>
> - [SSH into the router](https://openwrt.org/docs/guide-quick-start/sshadministration)
> - Run these commands to install the service file
> and start/enable it:
>
>    ```bash
>    cd /etc/init.d
>    wget https://raw.githubusercontent.com/lynxthecat/sqm-autorate/main/sqm-autorate
>    service sqm-autorate start
>    service sqm-autorate enable
>    ```
>
> When running as a service, the `autorate.sh` script outputs
> to `/tmp/sqm-autorate.log` when `enable_verbose_output` is set to '1'.
>
> Disabling logging when not required is a good idea given the rate of logging.
