#!/bin/sh
#   sqm-autorate-setup.sh: installs the sqm-autorate software on an OpenWRT router
#
#   Copyright (C) 2022
#       Nils Andreas Svee mailto:contact@lochnair.net (github @Lochnair)
#       Daniel Lakeland mailto:dlakelan@street-artists.org (github @dlakelan)
#       Mark Baker mailto:mark@e-bakers.com (github @Fail-Safe)
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

name="sqm-autorate"

owrt_release_file="/etc/os-release"
config_file="sqm-autorate.config"
service_file="sqm-autorate.service"
lua_file="sqm-autorate.lua"
get_stats="getstats.sh"
refl_icmp_file="reflectors-icmp.csv"
refl_udp_file="reflectors-udp.csv"
autorate_lib_path="/usr/lib/sqm-autorate"

# Set the repo_root URL that's the base for all files to be retrieved
if [ -z "$1" ]; then # $1 is empty (no parameter at all)
    repo_root="https://raw.githubusercontent.com/sqm-autorate/sqm-autorate/testing/lua-threads"
elif [ -z "$2" ]; then # $2 is empty (only one parameter)
    repo_root="https://raw.githubusercontent.com/sqm-autorate/sqm-autorate/${1}"
else # $1 & $2 are strings - build the root URL from scratch
    repo_root="https://raw.githubusercontent.com/${1}/sqm-autorate/${2}"
fi

check_for_sqm() {
    # Check first to see if SQM is installed and if not, offer to install it...
    if [ "$(opkg list-installed luci-app-sqm | wc -l)" = "0" ]; then
        # SQM is missing, let's prompt to install it...
        echo "!!! SQM (luci-app-sqm) is missing from your system and is required for sqm-autorate to function."
        read -p ">> Would you like to install SQM (luci-app-sqm) now? (y/n) " install_sqm
        install_sqm=$(echo "$install_sqm" | awk '{ print tolower($0) }')
        if [ "$install_sqm" = "y" ] || [ "$install_sqm" = "yes" ]; then
            if [ ! "$(opkg install luci-app-sqm)" = 0 ]; then
                echo "!!! An error occurred while trying to install luci-app-sqm. Please try again."
                exit 1
            else
                echo "> SQM (luci-app-sqm) was installed successfully and sqm-autorate setup will continue."
                echo "!! You must modify the '/etc/config/sqm' config file separately for your specific connection."
            fi
        else
            # We have to bail out if we don't have luci-app-sqm on OpenWrt...
            echo "> You must install SQM (luci-app-sqm) before using sqm-autorate. Aborting"
            exit 1
        fi
    else
        echo "> SQM (luci-app-sqm) already installed. Proceeding..."
    fi
}

#
# Main Routine of setup.sh starts here
# 

# Check for the presence of the OpenWrt os_release file and the proper contents
[ -f "$owrt_release_file" ] || { echo "Not an OpenWrt system ($owrt_release_file not present) Aborting." ; exit 1 ; }

# Check first line of $owrt_release_file has "NAME=OpenWRT"
is_openwrt=$(grep "$owrt_release_file" -e '^NAME=' | awk 'BEGIN { FS = "=" } { gsub(/"/, "", $2); print $2 }')
if [ $is_openwrt != OpenWrt ] ; then { echo "Bad name for OpenWrt (NAME=$is_openwrt). Aborting." ; exit 1 ; } fi

# It's an OpenWrt system - we can proceed with the installation
echo ">>> Installing on OpenWrt..."
echo ">>> Refreshing package cache. This may take a few moments..."
opkg update -V0
check_for_sqm

# Install the required packages for sqm-autorate ...
echo ">>> Installing required packages via opkg..."
opkg install -V0 curl lua luarocks lua-bit32 luaposix lualanes && luarocks install vstruct

# Try to install lua-argparse if possible...
echo ">> Looking for lua-argparse..."
if [ "$(opkg find lua-argparse | wc -l)" = "1" ]; then
    echo ">>> Installing lua-argparse..."
    opkg install -V0 lua-argparse
else
    echo "!! The lua-argparse package is not available for your distro. This means additional command-line options and arguments will not be available to you."
fi

# Now copy the important files to their destinations
[ -d "./.git" ] && is_git_proj=true || is_git_proj=false

if [ "$is_git_proj" = false ]; then
    # Need to curl some stuff down...
    echo ">>> Retrieving sqm-autorate operational files..."
    curl -o "$config_file" "$repo_root/config/$config_file"
    curl -o "$service_file" "$repo_root/service/$service_file"
    curl -o "$lua_file" "$repo_root/lib/$lua_file"
    curl -o "$get_stats" "$repo_root/lib/$get_stats"
    curl -o "$refl_icmp_file" "$repo_root/lib/$refl_icmp_file"
    curl -o "$refl_udp_file" "$repo_root/lib/$refl_udp_file"
else
    echo "> Since this is a Git project, local files will be used and will be COPIED into place instead of MOVED..."
fi

echo ">>> Putting config file into place..."
if [ -f "/etc/config/sqm-autorate" ]; then
    echo "!!! Warning: An sqm-autorate config file already exists. This new config file will be created as $name-NEW. Please review and merge any updates into your existing $name file."
    if [ "$is_git_proj" = true ]; then
        cp "./config/$config_file" "/etc/config/$name-NEW"
    else
        mv "./$config_file" "/etc/config/$name-NEW"
    fi
else
    if [ "$is_git_proj" = true ]; then
        cp "./config/$config_file" "/etc/config/$name"
    else
        mv "./$config_file" "/etc/config/$name"
    fi
fi

# transition section 1 - to be removed
# Remove/rename old format names "receive_xxx" and "transmit_xxx"
if grep -q -e 'receive' -e 'transmit' "/etc/config/$name" ; then
    echo ">>> Revising config option names..."
    uci rename sqm-autorate.@network[0].transmit_interface=upload_interface
    uci rename sqm-autorate.@network[0].receive_interface=download_interface
    uci rename sqm-autorate.@network[0].transmit_kbits_base=upload_base_kbits
    uci rename sqm-autorate.@network[0].receive_kbits_base=download_base_kbits

    t1=$( uci -q get sqm-autorate.@network[0].transmit_kbits_min )
    uci delete sqm-autorate.@network[0].transmit_kbits_min
    if [ -n "${t1}" ] && [ "${t1}" != "1500" ] ; then
        t2=$( uci -q get sqm-autorate.@network[0].upload_base_kbits )
        t1=$((t1 * 100 / t2))
        if [ $t1 -lt 10 ] ; then
            t1=10
        elif [ $t1 -gt 75 ] ; then
            t1=75
        fi
        uci set sqm-autorate.@network[0].upload_min_percent="${t1}"
    fi

    t1=$( uci -q get sqm-autorate.@network[0].receive_kbits_min )
    uci delete sqm-autorate.@network[0].receive_kbits_min
    if [ -n "${t1}" ] && [ "${t1}" != "1500" ] ; then
        t2=$( uci -q get sqm-autorate.@network[0].download_base_kbits )
        t1=$((t1 * 100 / t2))
        if [ $t1 -lt 10 ] ; then
            t1=10
        elif [ $t1 -gt 75 ] ; then
            t1=75
        fi
        uci set sqm-autorate.@network[0].download_min_percent="${t1}"
    fi

    uci -q add sqm-autorate advanced_settings 1> /dev/null

    t=$( uci -q get sqm-autorate.@output[0].hist_size )
    if [ -n "${t}" ] ; then
        uci delete sqm-autorate.@output[0].hist_size
        if [ "${t}" != "100" ] ; then
            uci set sqm-autorate.@advanced_settings[0].speed_hist_size="${t}"
        fi
    fi
    t=$( uci -q get sqm-autorate.@network[0].reflector_type )
    if [ -n "${t}" ] ; then
        uci delete sqm-autorate.@network[0].reflector_type
        if [ "${t}" != "icmp" ] ; then
            uci set sqm-autorate.@advanced_settings[0].reflector_type="${t}"
        fi
    fi

    uci set sqm-autorate.@advanced_settings[0].upload_delay_ms=15
    uci set sqm-autorate.@advanced_settings[0].download_delay_ms=15

    uci commit
fi

echo ">>> Copying sqm-autorate lib files into place..."
mkdir -p "$autorate_lib_path"
if [ "$is_git_proj" = true ]; then
    cp "./lib/$lua_file" "$autorate_lib_path/$lua_file"
    cp "./lib/$get_stats" "$autorate_lib_path/$get_stats"
    cp "./lib/$refl_icmp_file" "$autorate_lib_path/$refl_icmp_file"
    cp "./lib/$refl_udp_file" "$autorate_lib_path/$refl_udp_file"
else
    mv "./$lua_file" "$autorate_lib_path/$lua_file"
    mv "./$get_stats" "$autorate_lib_path/$get_stats"
    mv "./$refl_icmp_file" "$autorate_lib_path/$refl_icmp_file"
    mv "./$refl_udp_file" "$autorate_lib_path/$refl_udp_file"
fi

echo ">>> Making $lua_file and $get_stats executable..."
chmod +x "$autorate_lib_path/$lua_file" "$autorate_lib_path/$get_stats"

echo ">>> Putting service file into place..."
if [ "$is_git_proj" = true ]; then
    cp "./service/$service_file" "/etc/init.d/$name"
else
    mv "./$service_file" "/etc/init.d/$name"
fi
chmod a+x "/etc/init.d/$name"

echo "> All done! You can enable and start the service by executing 'service sqm-autorate enable && service sqm-autorate start'."
