#!/bin/sh
#   configure.sh: configures /etc/config/sqm-autorate
#
#   Copyright (C) 2022
#       Charles Corrigan mailto:chas-iot@runegate.org (github @chas-iot)
#
#   This Source Code Form is subject to the terms of the Mozilla Public
#   License, v. 2.0. If a copy of the MPL was not distributed with this
#   file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
#   Covered Software is provided under this License on an "as is"
#   basis, without warranty of any kind, either expressed, implied, or
#   statutory, including, without limitation, warranties that the
#   Covered Software is free of defects, merchantable, fit for a
#   particular purpose or non-infringing. The entire risk as to the
#   quality and performance of the Covered Software is with You.
#   Should any Covered Software prove defective in any respect, You
#   (not any Contributor) assume the cost of any necessary servicing,
#   repair, or correction. This disclaimer of warranty constitutes an
#   essential part of this License. No use of any Covered Software is
#   authorized under this License except under this disclaimer.
#

print_rerun () {
    echo "

================================================================================

To re-run this configuration at any time, type the following command at the
router shell prompt: '/usr/lib/sqm-autorate/configure.sh'

"
}

# trap control-c and print a message
handle_ctlc () {
    # print the notice about re-running
    echo "

SIGINT..."
    print_rerun

    # cleanup the trap
    trap "-" 2

    # exit program without quiting a remote ssh session - abuse of api :D
    exit -1 2>/dev/null
}
trap "handle_ctlc" 2

echo "
>> Starting the 'sqm-autorate' configuration script.

"

if [ ! -w /etc/config/sqm-autorate ]; then
    echo "/etc/config/sqm-autorate not found or not writable - exiting with no change
"
    # exit program without quiting a remote ssh session - abuse of api :D
    exit -1 2>/dev/null
fi

read -r -p "You may interupt this script and re-run later. To re-run, at the router shell
prompt, type '/usr/lib/sqm-autorate/configure.sh'

Press return, or type y or yes if you want guided assistance to set up a ready
   to run configuration file for 'sqm-autorate' [Y/n]: " do_config
do_config=$(echo "${do_config}" | awk '{ print tolower($0) }')
if [ -z "${do_config}" ] || [ "${do_config}" == "y" ] || [ "${do_config}" == "yes" ]; then
    . /lib/functions/network.sh
    network_flush_cache
    network_find_wan WAN_IF
    WAN_DEVICE=$(uci -q get network."${WAN_IF}".device)
    SETTINGS_UPLOAD_DEVICE=$(uci -q get sqm-autorate.@network[0].upload_interface)
    SETTINGS_DOWNLOAD_DEVICE=$(uci -q get sqm-autorate.@network[0].download_interface)
    SETTINGS_UPLOAD_SPEED=$(uci -q get sqm-autorate.@network[0].upload_base_kbits)
    SETTINGS_DOWNLOAD_SPEED=$(uci -q get sqm-autorate.@network[0].download_base_kbits)
    SETTINGS_LOG_LEVEL=$(uci -q get sqm-autorate.@output[0].log_level)

    INPUT=Y
    while [ $INPUT == "Y" ]; do
    echo "
This script does not reliably handle advanced or complex configurations of CAKE
You may be required to manually find and type the network device names

Here's the list of network devices known to CAKE:
$(tc qdisc | grep -i cake | grep -o ' dev [[:alnum:]]* ' | cut -d ' ' -f 3)"

        if [ -n "${SETTINGS_UPLOAD_DEVICE}" ]; then
            UPLOAD_DEVICE=$(tc qdisc | grep -i cake | grep -o -- " dev ${SETTINGS_UPLOAD_DEVICE} " | cut -d ' ' -f 3)
        fi
        if [ -z "${UPLOAD_DEVICE}" ]; then
            UPLOAD_DEVICE=$(tc qdisc | grep -i cake | grep -o -- " dev ${WAN_DEVICE} " | cut -d ' ' -f 3)
        fi

        if [ -n "${UPLOAD_DEVICE}" ]; then
            read -r -p "
press return to accept detected network upload device [${UPLOAD_DEVICE}]: " ACCEPT
            ACCEPT=$(echo "${ACCEPT}" | awk '{ print tolower($0) }')
            if [ -z "${ACCEPT}" ]; then
                GOOD=Y
            fi
        else
            echo "unable to automatically detect the network upload device"
            GOOD=N
        fi
        while [ $GOOD == "N" ]; do
            read -r -p "
These are the network devices known to CAKE
$(tc qdisc | grep -i cake | grep -o ' dev [[:alnum:]]* ' | cut -d ' ' -f 3)

Please type in the upload network device name: " UPLOAD_DEVICE
            x=$(tc qdisc | grep -i cake | grep -o -- " dev ${UPLOAD_DEVICE} " | cut -d ' ' -f 3)
            if [ -n "${x}" ]; then
                GOOD=Y
            fi
        done

        if [ -n "${SETTINGS_DOWNLOAD_DEVICE}" ]; then
            DOWNLOAD_DEVICE=$(tc qdisc | grep -i cake | grep -o -- " dev ${SETTINGS_DOWNLOAD_DEVICE} " | cut -d ' ' -f 3)
        fi
        if [ -z "${DOWNLOAD_DEVICE}" ]; then
            DOWNLOAD_DEVICE=$(tc qdisc | grep -i cake | grep -o -- " dev ifb4${UPLOAD_DEVICE} " | cut -d ' ' -f 3)
        fi

        if [ -z "${DOWNLOAD_DEVICE}" ]; then
            DOWNLOAD_DEVICE=$(tc qdisc | grep -i cake | grep -o -- " dev veth.* " | cut -d ' ' -f 3)
        fi
        if [ -n "${DOWNLOAD_DEVICE}" ]; then
            read -r -p "
press return to accept detected network download device [${DOWNLOAD_DEVICE}]: " ACCEPT
            ACCEPT=$(echo "${ACCEPT}" | awk '{ print tolower($0) }')
            if [ -z "${ACCEPT}" ]; then
                GOOD=Y
            fi
        else
            echo "unable to automatically detect the network download device"
            GOOD=N
        fi
        while [ $GOOD == "N" ]; do
            read -r -p "
These are the network devices known to CAKE
$(tc qdisc | grep -i cake | grep -o ' dev [[:alnum:]]* ' | cut -d ' ' -f 3)

Please type in the download network device name: " DOWNLOAD_DEVICE
            x=$(tc qdisc | grep -i cake | grep -o -- " dev ${DOWNLOAD_DEVICE} " | cut -d ' ' -f 3)
            if [ -n "${x}" ]; then
                GOOD=Y
            fi
        done

        echo "
Please type in the maximum speed that you reasonably expect from your network
on a good day. This should be a little lower than the speed advertised by your
ISP, unless you have specific knowledge otherwise. The speed is measured in
kbits per second, where 1 mbit = 1000 kbits, and 1 gbit = 1000000 kbits.
The speed should be input with just digits and no punctuation
"
        BAD=Y
        if [ -n "${SETTINGS_UPLOAD_SPEED}" ] && [[ $SETTINGS_UPLOAD_SPEED =~ ^[0-9]+$ ]]; then
            DEFAULT=" [${SETTINGS_UPLOAD_SPEED}]"
        else
            DEFAULT=""
        fi
        while [ $BAD == "Y" ]; do
            read -r -p "upload speed${DEFAULT}: " UPLOAD_SPEED
            if [ -n "${SETTINGS_UPLOAD_SPEED}" ] && [ -z "${UPLOAD_SPEED}" ]; then
                UPLOAD_SPEED=$SETTINGS_UPLOAD_SPEED
                BAD=N
            elif [[ $UPLOAD_SPEED =~ ^[0-9]+$ ]]; then
                BAD=N
            else
                echo "
please input digits only"
            fi
        done

        BAD=Y
        while [ $BAD == "Y" ]; do
            if [ -n "${SETTINGS_DOWNLOAD_SPEED}" ] && [[ $SETTINGS_DOWNLOAD_SPEED =~ ^[0-9]+$ ]]; then
                DEFAULT=" [${SETTINGS_DOWNLOAD_SPEED}]"
            else
                DEFAULT=""
            fi
            read -r -p "download speed${DEFAULT}: " DOWNLOAD_SPEED
            if [ -n "${SETTINGS_DOWNLOAD_SPEED}" ] && [ -z "${DOWNLOAD_SPEED}" ]; then
                DOWNLOAD_SPEED=$SETTINGS_DOWNLOAD_SPEED
                BAD=N
            elif [[ $DOWNLOAD_SPEED =~ ^[0-9]+$ ]]; then
                BAD=N
            else
                echo "
please input digits only"
            fi
        done
        echo "
The minimum tolerable speed is calculated from the speeds input above.
You may override the recommendation with care. The minimum must be lower than
the original speed. The input may be recalculated slightly, and in that case,
will be re-displayed for confirmation
"
        if [ "$UPLOAD_SPEED" -le 3000 ]; then
            UPLOAD_PERCENT=75
            UPLOAD_MINIMUM=$((UPLOAD_SPEED * 3 / 4))
            UPLOAD_HARD_MINIMUM=$UPLOAD_MINIMUM

        elif [ "$UPLOAD_SPEED" -le 11250 ]; then
            UPLOAD_PERCENT=$((2250 * 100 / UPLOAD_SPEED))
            UPLOAD_MINIMUM=$((UPLOAD_SPEED * UPLOAD_PERCENT / 100))
            t=$((UPLOAD_MINIMUM * 100 / UPLOAD_PERCENT))
            while [ $t -lt "$UPLOAD_SPEED" ] || [ $UPLOAD_MINIMUM -lt 2250 ]; do
                UPLOAD_PERCENT=$((UPLOAD_PERCENT + 1))
                UPLOAD_MINIMUM=$((UPLOAD_SPEED * UPLOAD_PERCENT / 100))
                t=$((UPLOAD_MINIMUM * 100 / UPLOAD_PERCENT))
            done
            UPLOAD_HARD_MINIMUM=$UPLOAD_MINIMUM

        else
            UPLOAD_MINIMUM=$((UPLOAD_SPEED / 5))
            UPLOAD_PERCENT=20
            UPLOAD_HARD_MINIMUM=$((UPLOAD_SPEED / 10))
        fi

        BAD=Y
        while [ $BAD == "Y" ]; do
            read -r -p "upload minimum speed [${UPLOAD_MINIMUM}]: " OVERRIDE_UPLOAD
            if [ -z "${OVERRIDE_UPLOAD}" ]; then
                BAD=N
            elif [[ $OVERRIDE_UPLOAD =~ ^[0-9]+$ ]]; then
                if [ "$OVERRIDE_UPLOAD" -lt "$UPLOAD_SPEED" ]; then
                    if [ "$OVERRIDE_UPLOAD" -ne $UPLOAD_MINIMUM ]; then
                        UPLOAD_PERCENT=$((OVERRIDE_UPLOAD * 100 / UPLOAD_SPEED))
                        UPLOAD_MINIMUM=$((UPLOAD_SPEED * UPLOAD_PERCENT / 100))
                        if [ $UPLOAD_PERCENT -lt 10 ]; then
                            UPLOAD_PERCENT=10
                        elif [ $UPLOAD_PERCENT -gt 75 ]; then
                            UPLOAD_PERCENT=75
                        elif [ $UPLOAD_MINIMUM -lt $UPLOAD_HARD_MINIMUM ]; then
                            UPLOAD_MINIMUM=$UPLOAD_HARD_MINIMUM
                            UPLOAD_PERCENT=$((UPLOAD_MINIMUM * 100 / UPLOAD_SPEED))
                        else
                            UPLOAD_MINIMUM=$((UPLOAD_SPEED * UPLOAD_PERCENT / 100))
                            t=$((UPLOAD_MINIMUM * 100 / UPLOAD_PERCENT))
                            if [ $t -lt "$UPLOAD_SPEED" ]; then
                                UPLOAD_PERCENT=$((UPLOAD_PERCENT + 1))
                            fi
                        fi
                        UPLOAD_MINIMUM=$((UPLOAD_SPEED * UPLOAD_PERCENT / 100))
                            echo "
please confirm recalculated value"
                    else
                        BAD=N
                    fi
                else
                    echo "
please input digits only and ensure that the minimum is less than the original"
                fi
            fi
        done

        if [ "$DOWNLOAD_SPEED" -le 3000 ]; then
            DOWNLOAD_PERCENT=75
            DOWNLOAD_MINIMUM=$((DOWNLOAD_SPEED * 3 / 4))
            DOWNLOAD_HARD_MINIMUM=$DOWNLOAD_MINIMUM

        elif [ "$DOWNLOAD_SPEED" -le 11250 ]; then
            DOWNLOAD_PERCENT=$((2250 * 100 / DOWNLOAD_SPEED))
            DOWNLOAD_MINIMUM=$((DOWNLOAD_SPEED * DOWNLOAD_PERCENT / 100))
            t=$((DOWNLOAD_MINIMUM * 100 / DOWNLOAD_PERCENT))
            while [ $t -lt "$DOWNLOAD_SPEED" ] || [ $DOWNLOAD_MINIMUM -lt 2250 ]; do
                DOWNLOAD_PERCENT=$((DOWNLOAD_PERCENT + 1))
                DOWNLOAD_MINIMUM=$((DOWNLOAD_SPEED * DOWNLOAD_PERCENT / 100))
                t=$((DOWNLOAD_MINIMUM * 100 / DOWNLOAD_PERCENT))
            done
            DOWNLOAD_HARD_MINIMUM=$DOWNLOAD_MINIMUM

        else
            DOWNLOAD_MINIMUM=$((DOWNLOAD_SPEED / 5))
            DOWNLOAD_PERCENT=20
            DOWNLOAD_HARD_MINIMUM=$((DOWNLOAD_SPEED / 10))
        fi

        BAD=Y
        while [ $BAD == "Y" ]; do
            read -r -p "download minimum speed [${DOWNLOAD_MINIMUM}]: " OVERRIDE_DOWNLOAD
            if [ -z "${OVERRIDE_DOWNLOAD}" ]; then
                BAD=N
            elif [[ $OVERRIDE_DOWNLOAD =~ ^[0-9]+$ ]]; then
                if [ "$OVERRIDE_DOWNLOAD" -lt "$DOWNLOAD_SPEED" ]; then
                    if [ "$OVERRIDE_DOWNLOAD" -ne $DOWNLOAD_MINIMUM ]; then
                        DOWNLOAD_PERCENT=$((OVERRIDE_DOWNLOAD * 100 / DOWNLOAD_SPEED))
                        DOWNLOAD_MINIMUM=$((DOWNLOAD_SPEED * DOWNLOAD_PERCENT / 100))
                        if [ $DOWNLOAD_PERCENT -lt 10 ]; then
                            DOWNLOAD_PERCENT=10
                        elif [ $DOWNLOAD_PERCENT -gt 70 ]; then
                            DOWNLOAD_PERCENT=75
                        elif [ $DOWNLOAD_MINIMUM -lt $DOWNLOAD_HARD_MINIMUM ]; then
                            DOWNLOAD_MINIMUM=$DOWNLOAD_HARD_MINIMUM
                            DOWNLOAD_PERCENT=$((DOWNLOAD_MINIMUM * 100 / DOWNLOAD_SPEED))
                        else
                            DOWNLOAD_MINIMUM=$((DOWNLOAD_SPEED * DOWNLOAD_PERCENT / 100))
                            t=$((DOWNLOAD_MINIMUM * 100 / DOWNLOAD_PERCENT))
                            if [ $t -lt "$DOWNLOAD_SPEED" ]; then
                                DOWNLOAD_PERCENT=$((DOWNLOAD_PERCENT + 1))
                            fi
                        fi
                        DOWNLOAD_MINIMUM=$((DOWNLOAD_SPEED * DOWNLOAD_PERCENT / 100))
                            echo "
please confirm recalculated value"
                    else
                        BAD=N
                    fi
                else
                    echo "
please input digits only and ensure that the minimum is less than the original"
                fi
            fi
        done

        GOOD=N
        while [ $GOOD == "N" ]; do
            read -r -p "
'sqm-autorate' logging uses storage on the router
Choose one of the following log levels
- FATAL     - minimal
- ERROR     - minimal
- WARN      - minimal, recommended
- INFO      - typically a very few Kb per day showing settings changes, however
                could be more depending on the network activity
- DEBUG     - for error finding, developers; use for short periods only
- TRACE     - for developers; use for short periods only

Type in one of the log levels, or press return to accept [${SETTINGS_LOG_LEVEL}]: " LOG_LEVEL
            LOG_LEVEL=$(echo "${LOG_LEVEL}" | awk '{ print toupper($0) }')
            if [ -z "${LOG_LEVEL}" ]; then
                LOG_LEVEL="${SETTINGS_LOG_LEVEL}"
                GOOD=Y
            elif [ "${LOG_LEVEL}" == "FATAL" ] ||
                [ "${LOG_LEVEL}" == "ERROR" ] ||
                [ "${LOG_LEVEL}" == "WARN" ] ||
                [ "${LOG_LEVEL}" == "INFO" ] ||
                [ "${LOG_LEVEL}" == "DEBUG" ] ||
                [ "${LOG_LEVEL}" == "TRACE" ]; then
                GOOD=Y
            fi
        done

        read -r -p "
sqm-autorate can output statistics that may be analysed with Julia scripts
( https://github.com/sqm-autorate/sqm-autorate/tree/testing/lua-threads#graphical-analysis ),
spreadsheets, or other statistical software.
The statistics use about 12 Mb of storage per day on the router

Type y or yes to choose to output the statistics [y/N]: " STATS
        STATS=$(echo "${STATS}" | awk '{ print tolower($0) }')
        if [ "${STATS}" == "y" ] || [ "${STATS}" == "yes" ]; then
            SUPPRESS_STATISTICS=No
        else
            SUPPRESS_STATISTICS=Yes
        fi

        if [ ! -x /etc/init.d/sqm-autorate ]; then
            echo "
/etc/init.d/sqm-autorate - not found or not executable, skipping (auto)start"
        else
            read -r -p "
Do you want to automatically start 'sqm-autorate' at reboot [Y/n]: " STARTAUTO
            STARTAUTO=$(echo "${STARTAUTO}" | awk '{ print tolower($0) }')
            if [ -z "${STARTAUTO}" ] || [ "${STARTAUTO}" == "y" ] || [ "${STARTAUTO}" == "yes" ]; then
                START_AUTO=Yes
            else
                START_AUTO=No
            fi

            read -r -p "
Do you want to start 'sqm-autorate' now [Y/n]: " STARTNOW
            STARTNOW=$(echo "${STARTNOW}" | awk '{ print tolower($0) }')
            if [ -z "${STARTNOW}" ] || [ "${STARTNOW}" == "y" ] || [ "${STARTNOW}" == "yes" ]; then
                START_NOW=Yes
            else
                START_NOW=No
            fi
        fi

        read -r -p "

================================================================================

Settings:

      UPLOAD DEVICE: ${UPLOAD_DEVICE}
    DOWNLOAD DEVICE: ${DOWNLOAD_DEVICE}

       UPLOAD SPEED: ${UPLOAD_SPEED}
     UPLOAD PERCENT: ${UPLOAD_PERCENT}
     UPLOAD MINIMUM: ${UPLOAD_MINIMUM}

     DOWNLOAD SPEED: ${DOWNLOAD_SPEED}
   DOWNLOAD PERCENT: ${DOWNLOAD_PERCENT}
   DOWNLOAD MINIMUM: ${DOWNLOAD_MINIMUM}

          LOG LEVEL: ${LOG_LEVEL}
SUPPRESS STATISTICS: ${SUPPRESS_STATISTICS}

Start automatically: ${START_AUTO}
          Start now: ${START_NOW}

Type y or yes to confirm the above input and continue;
  <ctrl-c> to interrupt and exit;  or
  anything else to start over [y/N]: " RESPONSE
        RESPONSE=$(echo "${RESPONSE}" | awk '{ print tolower($0) }')
        if [ "${RESPONSE}" == "y" ] || [ "${RESPONSE}" == "yes" ]; then
            INPUT=N
        else
            INPUT=Y
            echo "
restarting input
            "
        fi
    done

    if [ "$UPLOAD_SPEED" -le 3000 ] || [ "$DOWNLOAD_SPEED" -le 3000 ]; then
        echo "
================================================================================

Please visit https://forum.openwrt.org/t/cake-w-adaptive-bandwidth/108848
and ask about further measures that may help in improving experience on a
relatively low bandwidth link.

This suggestion is provided because either your upload or download has a
maximum speed of 3 Mbits per second or lower.

At speeds below 3Mbps, low latency applications may not work well, even with
good queue management. The cause of this is that individual packets take longer
and longer to send, causing disruptions even with perfect queueing.

Note that the above forum requires registration before posting."
    fi

    uci set sqm-autorate.@network[0].upload_interface="${UPLOAD_DEVICE}"
    uci set sqm-autorate.@network[0].download_interface="${DOWNLOAD_DEVICE}"

    uci set sqm-autorate.@network[0].upload_base_kbits="${UPLOAD_SPEED}"
    uci set sqm-autorate.@network[0].download_base_kbits="${DOWNLOAD_SPEED}"

    uci set sqm-autorate.@network[0].upload_min_percent="${UPLOAD_PERCENT}"
    uci set sqm-autorate.@network[0].download_min_percent="${DOWNLOAD_PERCENT}"

    uci set sqm-autorate.@output[0].log_level="${LOG_LEVEL}"
    uci set sqm-autorate.@output[0].suppress_statistics="${SUPPRESS_STATISTICS}"

    uci commit

    if [ -x /etc/init.d/sqm-autorate ]; then
        if [ "${START_AUTO}" == "Yes" ]; then
            echo "
Enabling 'sqm-autorate' service"
            /etc/init.d/sqm-autorate enable
        fi
        if [ "${START_NOW}" == "Yes" ]; then
            echo "
Starting 'sqm-autorate' service"
            /etc/init.d/sqm-autorate stop
            /etc/init.d/sqm-autorate start
        fi
    fi

fi

# tell the user how to rerun
print_rerun

# clear the trap before exit
trap "-" 2
