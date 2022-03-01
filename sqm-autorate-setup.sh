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

TS=$(date -u -Iminutes)      # to avoid identifying location by timezone

if [ -z "$1" ]; then        # no parameters, use default repo and branch
    repo_root="https://raw.githubusercontent.com/sqm-autorate/sqm-autorate/testing/lua-threads"
    INSTALLATION="  [release]"

elif [ -z "$2" ]; then      # one parameter, use specified branch in default repo
    repo_root="https://raw.githubusercontent.com/sqm-autorate/sqm-autorate/${1}"
    INSTALLATION="\\\\n        branch ${1}\\\\n        ${TS}"

else                        # two parameters, use specified repo and specified branch
    repo_root="https://raw.githubusercontent.com/${1}/sqm-autorate/${2}"
    INSTALLATION="\\\\n        ${repo_root}\\\\n        ${TS}"

fi

name="sqm-autorate"

owrt_release_file="/etc/os-release"
config_file="sqm-autorate.config"
service_file="sqm-autorate.service"
lua_file="sqm-autorate.lua"
get_stats="getstats.sh"
refl_icmp_file="reflectors-icmp.csv"
refl_udp_file="reflectors-udp.csv"
autorate_lib_path="/usr/lib/sqm-autorate"
settings_file="sqma-settings.lua"
utilities_file="sqma-utilities.lua"
configure_file="configure.sh"

# start of pre-installation checks
cake=$(tc qdisc | grep -i cake)
if [ -z "${cake}" ]; then
    echo
    echo "This installation script cannot find an instance of the CAKE SQM running on any"
    echo "network interface. 'sqm-autorate' currently works only with the CAKE SQM"
    echo "Please install and configure CAKE before attempting to install sqm-autorate"
    echo
    echo "After CAKE is installed and configured, its presence is detected by the"
    echo "shell command 'tc qdisc | grep -i cake'"
    echo
    echo "Exiting with no change"
    exit 0
fi

is_openwrt=unknown
if [ -f "$owrt_release_file" ]; then
    is_openwrt=$(grep "$owrt_release_file" -e '^NAME=' | awk 'BEGIN { FS = "=" } { gsub(/"/, "", $2); print $2 }')
fi
if [ "${is_openwrt}" != "OpenWrt" ]; then
    echo
    echo "Not able to determine whether this installation is on an OpenWRT system"
    echo "expected 'OpenWrt', found '${is_openwrt}'"
    echo "The installation script should run correctly on many OpenWRT derivatives"
    echo
    read -r -p ">> Please confirm that you wish to continue installation? (y/n)" go_ahead
    go_ahead=$(echo "${go_ahead}" | awk '{ print tolower($0) }')
    if [ "${go_ahead}" != "y" ] && [ "${go_ahead}" != "yes" ]; then
        echo
        echo "Exiting with no change"
        exit 0
    fi
fi

if [ -x /etc/init.d/sqm-autorate ]; then
    echo ">>> Stopping 'sqm-autorate'"
    /etc/init.d/sqm-autorate stop
fi

# work out whether to use curl or wget based on available images
curl=''
transfer=''
if [ "$(which curl | wc -l)" != "0" ]; then
    transfer='curl -s -o'

elif [ "$(which wget | wc -l)" != "0" ]; then
    transfer='wget -q -O'

else
    curl=curl
    transfer='curl -s -o'
fi

# we can proceed with the installation
echo ">>> Refreshing package cache. This may take several minutes..."
opkg update -V0

# Try to install lua-argparse if possible...
lua_argparse=''
if [ "$(opkg find lua-argparse | wc -l)" = "1" ]; then
    lua_argparse='lua-argparse'
else
    echo
    echo "The lua-argparse package is not available for your distro."
    echo "This means that some additional command-line options and arguments will not be available to you."
fi

# Install the required packages for sqm-autorate ...
echo ">>> Installing required packages via opkg..."
install="opkg install -V0 lua luarocks lua-bit32 luaposix lualanes ${lua_argparse} ${curl}"
$install

echo ">>> Installing required packages via luarocks..."
luarocks install vstruct

[ -d "./.git" ] && is_git_proj=true || is_git_proj=false

echo ">>> creating ${autorate_lib_path}"
mkdir -p "${autorate_lib_path}"

if [ "$is_git_proj" = false ]; then
    # Need to wget some stuff down...
    echo ">>> Downloading sqm-autorate files..."
    (
        cd "${autorate_lib_path}" || { echo "ERROR: could not find ${autorate_lib_path}"; exit; }
        $transfer "$config_file" "$repo_root/config/$config_file"
        $transfer "$service_file" "$repo_root/service/$service_file"
        $transfer "$lua_file" "$repo_root/lib/$lua_file"
        $transfer "$settings_file" "$repo_root/lib/$settings_file"
        $transfer "$utilities_file" "$repo_root/lib/$utilities_file"
        $transfer "$get_stats" "$repo_root/lib/$get_stats"
        $transfer "$refl_icmp_file" "$repo_root/lib/$refl_icmp_file"
        $transfer "$refl_udp_file" "$repo_root/lib/$refl_udp_file"
        $transfer "$configure_file" "$repo_root/lib/$configure_file"
    )
fi

if [ "$is_git_proj" = true ]; then
    echo ">>> Copying sqm-autorate lib files into place..."
    cp "./lib/$lua_file" "$autorate_lib_path/$lua_file"
    cp "./lib/$settings_file" "$autorate_lib_path/$settings_file"
    cp "./lib/$utilities_file" "$autorate_lib_path/$utilities_file"
    cp "./lib/$get_stats" "$autorate_lib_path/$get_stats"
    cp "./lib/$refl_icmp_file" "$autorate_lib_path/$refl_icmp_file"
    cp "./lib/$refl_udp_file" "$autorate_lib_path/$refl_udp_file"
    cp "./lib/$configure_file" "$autorate_lib_path/$configure_file"
fi

echo ">>> Making $lua_file, $get_stats, and $configure_file executable..."
chmod +x "$autorate_lib_path/$lua_file" "$autorate_lib_path/$get_stats" "$autorate_lib_path/$configure_file"

echo ">>> Putting config file into place..."
if [ -f "/etc/config/sqm-autorate" ]; then
    echo "!!! Warning: An sqm-autorate config file already exists. This new config file will be created as $name-NEW. Please review and merge any updates into your existing $name file."
    if [ "$is_git_proj" = true ]; then
        cp "./config/$config_file" "/etc/config/$name-NEW"
    else
        mv "${autorate_lib_path}/$config_file" "/etc/config/$name-NEW"
    fi
else
    if [ "$is_git_proj" = true ]; then
        cp "./config/$config_file" "/etc/config/$name"
    else
        mv "${autorate_lib_path}/$config_file" "/etc/config/$name"
    fi
fi

echo ">>> Putting service file into place..."
if [ "$is_git_proj" = true ]; then
    cp "./service/$service_file" "/etc/init.d/$name"
else
    mv "${autorate_lib_path}/$service_file" "/etc/init.d/$name"
fi
chmod a+x "/etc/init.d/$name"


# transition section 1 - to be removed for release v0.6 or later
if grep -q -e 'receive' -e 'transmit' "/etc/config/$name"; then
    echo ">>> Revising config option names..."
    uci rename sqm-autorate.@network[0].transmit_interface=upload_interface
    uci rename sqm-autorate.@network[0].receive_interface=download_interface
    uci rename sqm-autorate.@network[0].transmit_kbits_base=upload_base_kbits
    uci rename sqm-autorate.@network[0].receive_kbits_base=download_base_kbits

    t1=$(uci -q get sqm-autorate.@network[0].transmit_kbits_min)
    uci delete sqm-autorate.@network[0].transmit_kbits_min
    if [ -n "${t1}" ] && [ "${t1}" != "1500" ]; then
        t2=$(uci -q get sqm-autorate.@network[0].upload_base_kbits)
        t1=$((t1 * 100 / t2))
        if [ $t1 -lt 10 ]; then
            t1=10
        elif [ $t1 -gt 75 ]; then
            t1=75
        fi
        uci set sqm-autorate.@network[0].upload_min_percent="${t1}"
    fi

    t1=$(uci -q get sqm-autorate.@network[0].receive_kbits_min)
    uci delete sqm-autorate.@network[0].receive_kbits_min
    if [ -n "${t1}" ] && [ "${t1}" != "1500" ]; then
        t2=$(uci -q get sqm-autorate.@network[0].download_base_kbits)
        t1=$((t1 * 100 / t2))
        if [ $t1 -lt 10 ]; then
            t1=10
        elif [ $t1 -gt 75 ]; then
            t1=75
        fi
        uci set sqm-autorate.@network[0].download_min_percent="${t1}"
    fi

    uci -q add sqm-autorate advanced_settings 1>/dev/null

    t=$(uci -q get sqm-autorate.@output[0].hist_size)
    if [ -n "${t}" ]; then
        uci delete sqm-autorate.@output[0].hist_size
        if [ "${t}" != "100" ]; then
            uci set sqm-autorate.@advanced_settings[0].speed_hist_size="${t}"
        fi
    fi
    t=$(uci -q get sqm-autorate.@network[0].reflector_type)
    if [ -n "${t}" ]; then
        uci delete sqm-autorate.@network[0].reflector_type
        if [ "${t}" != "icmp" ]; then
            uci set sqm-autorate.@advanced_settings[0].reflector_type="${t}"
        fi
    fi

    uci set sqm-autorate.@advanced_settings[0].upload_delay_ms=15
    uci set sqm-autorate.@advanced_settings[0].download_delay_ms=15

    uci commit
fi

echo ">>> updating VERSION string to include: ${INSTALLATION}"
sed -i-orig "/n    /! s;^\([[:blank:]]*local[[:blank:]]*_VERSION[[:blank:]]*=[[:blank:]]*\".*\)\"[[:blank:]]*$;\1${INSTALLATION}\";" "${autorate_lib_path}/${lua_file}"

echo "
>>> Installation complete, about to start configuration."

if [ ! -x $autorate_lib_path/$configure_file ]; then
    echo "${autorate_lib_path}/${configure_file} is not found or not executable"
else
    $autorate_lib_path/$configure_file
fi
