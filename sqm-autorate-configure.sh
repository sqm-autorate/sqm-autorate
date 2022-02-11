#!/bin/sh
#   sqm-autorate-configure.sh: configures /etc/config/sqm-autorate
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

echo ">> Type y or yes if you want some guided assistance to set up a ready to run"
read -p "   configuration file for sqm-autorate' (y/n): " do_config
do_config=$(echo "${do_config}" | awk '{ print tolower($0) }')
if [ "${do_config}" == "y" ] || [ "${do_config}" == "yes" ]; then
    echo "
This script does not reliably handle advanced or complex configurations of CAKE
You may be required to manually find and type the network device names

You may interupt this script and re-run later. To re-run, at the router shell
prompt, type '/usr/lib/sqm-autorate/sqm-autorate-configure.sh'"

    echo "
Here's the list of network devices known to CAKE:
$(tc qdisc | grep -i cake | grep -o ' dev [[:alnum:]]* ' | cut -d ' ' -f 3)
"
    . /lib/functions/network.sh
    network_flush_cache
    network_find_wan WAN_IF
    WAN_DEVICE=$(uci -q get network.$WAN_IF.device)

    INPUT=Y
    while [ $INPUT == "Y" ]; do
        UPLOAD_DEVICE=$(tc qdisc | grep -i cake | grep -o -- " dev ${WAN_DEVICE} " | cut -d ' ' -f 3)
        if [ -z "${UPLOAD_DEVICE}" ]; then
            echo "unable to detect the network upload device"
            GOOD=N
        else
            read -p "press return to accept detected network upload device [${UPLOAD_DEVICE}]: " ACCEPT
            ACCEPT=$(echo "${ACCEPT}" | awk '{ print tolower($0) }')
            if [ -z "${ACCEPT}" ]; then
                GOOD=Y
            fi
        fi
        while [ $GOOD == "N" ]; do
            echo "
Type in one of the following network devices
$(tc qdisc | grep -i cake | grep -o ' dev [[:alnum:]]* ' | cut -d ' ' -f 3)
"
            read -p "please type in the upload device name: " UPLOAD_DEVICE
            x=$(tc qdisc | grep -i cake | grep -o -- " dev ${UPLOAD_DEVICE} " | cut -d ' ' -f 3)
            if [ -n "${x}" ]; then
                GOOD=Y
            fi
        done
        echo

        DOWNLOAD_DEVICE=$(tc qdisc | grep -i cake | grep -o -- " dev ifb4${UPLOAD_DEVICE} " | cut -d ' ' -f 3)
        if [ -z "${DOWNLOAD_DEVICE}" ]; then
            DOWNLOAD_DEVICE=$(tc qdisc | grep -i cake | grep -o -- " dev veth.* " | cut -d ' ' -f 3)
        fi
        if [ -z "${DOWNLOAD_DEVICE}" ]; then
            echo "unable to detect the network download device"
            GOOD=N
        else
            read -p "press return to accept detected network download device [${DOWNLOAD_DEVICE}]: " ACCEPT
            ACCEPT=$(echo "${ACCEPT}" | awk '{ print tolower($0) }')
            if [ -z "${ACCEPT}" ]; then
                GOOD=Y
            fi
        fi
        while [ $GOOD == "N" ]; do
            echo "
Type in one of the following network devices
$(tc qdisc | grep -i cake | grep -o ' dev [[:alnum:]]* ' | cut -d ' ' -f 3)
"
            read -p "please type in the download device name: " DOWNLOAD_DEVICE
            x=$(tc qdisc | grep -i cake | grep -o -- " dev ${DOWNLOAD_DEVICE} " | cut -d ' ' -f 3)
            if [ -n "${x}" ]; then
                GOOD=Y
            fi
        done

        echo "
Please type in the maximum speeds that you reasonably expect from your network
on a good day. The speed is measured in kbits per second where 1 mbit per
second = 1000 kbits per second, and 1 gbit per second = 1000000.
The speed should be input with no punctuation
"
        BAD=Y
        while [ $BAD == "Y" ]; do
            read -p "upload speed: " UPLOAD_SPEED
            if [[ $UPLOAD_SPEED =~ ^[0-9]+$ ]]; then
                BAD=N
            else
                echo "please input digits only"
            fi
        done
        BAD=Y
        while [ $BAD == "Y" ]; do
            read -p "download speed: " DOWNLOAD_SPEED
            if [[ $DOWNLOAD_SPEED =~ ^[0-9]+$ ]]; then
                BAD=N
            else
                echo "please input digits only"
            fi
        done

        if [ $UPLOAD_SPEED -ge 50000 ]; then
            UPLOAD_MINIMUM=$((UPLOAD_SPEED / 5))
            UPLOAD_PERCENT=20

        elif [ $UPLOAD_SPEED -gt 20000 ]; then
            UPLOAD_PERCENT=$((10000 * 100 / UPLOAD_SPEED))
            UPLOAD_PERCENT=$((UPLOAD_PERCENT + 1))
            UPLOAD_MINIMUM=$((UPLOAD_SPEED * UPLOAD_PERCENT / 100))

        else
            UPLOAD_MINIMUM=$((UPLOAD_SPEED / 2))
            UPLOAD_PERCENT=50
        fi

        if [ $DOWNLOAD_SPEED -ge 50000 ]; then
            DOWNLOAD_MINIMUM=$((DOWNLOAD_SPEED / 5))
            DOWNLOAD_PERCENT=20

        elif [ $DOWNLOAD_SPEED -gt 20000 ]; then
            DOWNLOAD_PERCENT=$((10000 * 100 / DOWNLOAD_SPEED))
            DOWNLOAD_PERCENT=$((DOWNLOAD_PERCENT + 1))
            DOWNLOAD_MINIMUM=$((DOWNLOAD_SPEED * DOWNLOAD_PERCENT / 100))

        else
            DOWNLOAD_MINIMUM=$((DOWNLOAD_SPEED / 2))
            DOWNLOAD_PERCENT=50
        fi

        GOOD=N
        while [ $GOOD == "N" ]; do
            echo "
sqm-autorate logging uses storage on the router
Choose one of the following log levels
- FATAL     - minimal
- ERROR     - minimal
- WARN      - minimal, recommended
- INFO      - around 100 Kb per day, showing settings changes
- DEBUG     - for error finding, developers
- TRACE     - for developers
"
            read -p "Type in one of the log levels, or press return to accept [WARN]: " LOG_LEVEL
            LOG_LEVEL=$(echo "${LOG_LEVEL}" | awk '{ print toupper($0) }')
            if [ -z "${LOG_LEVEL}" ]; then
                LOG_LEVEL=WARN
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

        echo "
sqm-autorate statistics use about 12 Mb of storage per day on the router"
        read -p "Type y or yes to choose to output the statistics [no]: " STATS
        STATS=$(echo "${STATS}" | awk '{ print tolower($0) }')
        if [ "${STATS}" == "y" ] || [ "${STATS}" == "yes" ]; then
            SUPPRESS_STATISTICS=no
        else
            SUPPRESS_STATISTICS=yes
        fi

        echo "

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

Please confirm the above input
"
        read -p "Type y or yes to confirm and continue, otherwise start over: " RESPONSE
        RESPONSE=$(echo "${RESPONSE}" | awk '{ print tolower($0) }')
        if [ "${RESPONSE}" == "y" ] || [ "${RESPONSE}" == "yes" ]; then
            INPUT=N
        else
            INPUT=Y
        fi
    done
    uci set sqm-autorate.@network[0].upload_interface="${UPLOAD_DEVICE}"
    uci set sqm-autorate.@network[0].download_interface="${DOWNLOAD_DEVICE}"

    uci set sqm-autorate.@network[0].upload_base_kbits="${UPLOAD_SPEED}"
    uci set sqm-autorate.@network[0].download_base_kbits="${DOWNLOAD_SPEED}"

    uci set sqm-autorate.@network[0].upload_min_percent="${UPLOAD_PERCENT}"
    uci set sqm-autorate.@network[0].download_min_percent="${DOWNLOAD_PERCENT}"

    uci set sqm-autorate.@output[0].log_level="${LOG_LEVEL}"
    uci set sqm-autorate.@output[0].suppress_statistics="${SUPPRESS_STATISTICS}"

    uci commit
fi
echo
echo ">> to re-run this configuration at any time, type the following command at the"
echo "   router shell prompt: '/usr/lib/sqm-autorate/sqm-autorate-configure.sh'"
