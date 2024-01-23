#!/bin/sh
#   sqm-autorate-setup.sh: installs the sqm-autorate software on an OpenWRT router
#
#   Copyright (C) 2022
#       Nils Andreas Svee mailto:contact@lochnair.net (github @Lochnair)
#       Daniel Lakeland mailto:dlakelan@street-artists.org (github @dlakelan)
#       Mark Baker mailto:mark@vpost.net (github @Fail-Safe)
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

TS=$(date -u -Iminutes) # to avoid identifying location by timezone

if [ -z "$1" ]; then # no parameters, use default repo and branch
    repo_tar="https://api.github.com/repos/sqm-autorate/sqm-autorate/tarball/main"
    INSTALLATION="  [release]"

elif [ -z "$2" ]; then # one parameter, use specified branch in default repo
    repo_tar="https://api.github.com/repos/sqm-autorate/sqm-autorate/tarball/${1}"
    INSTALLATION="\\\\n        branch ${1}\\\\n        ${TS}"

else # two parameters, use specified repo and specified branch
    repo_tar="https://api.github.com/repos/${1}/sqm-autorate/tarball/${2}"
    INSTALLATION="\\\\n        ${repo_tar}\\\\n        ${TS}"

fi

name="sqm-autorate"

autorate_lib_path="/usr/lib/sqm-autorate"
config_file="sqm-autorate.config"
configure_file="configure.sh"
lua_file="sqm-autorate.lua"
owrt_release_file="/etc/os-release"
service_file="sqm-autorate.service"

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

if [ -x /etc/init.d/sqm-autorate ] && /etc/init.d/sqm-autorate running; then
    echo ">>> Stopping $name"
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

echo ">>> Creating ${autorate_lib_path}"
mkdir -p "${autorate_lib_path}"

if [ "$is_git_proj" = false ]; then
    # Need to transfer some stuff down...
    echo ">>> Downloading sqm-autorate files..."
    (
        cd "${autorate_lib_path}" || {
            echo "ERROR: could not find ${autorate_lib_path}"
            exit 1
        }
        $transfer "$repo_tar" "/tmp/sqm-autorate-install.tar.gz"
        tar -xzf "/tmp/sqm-autorate-install.tar.gz" -C /tmp
    )
fi

echo ">>> Putting lib files into place..."
if [ "$is_git_proj" = true ]; then
    cp -r ./lib/. "${autorate_lib_path}"
else
    cp -r /tmp/sqm-autorate-sqm-autorate-*/lib/. "${autorate_lib_path}"
fi

echo ">>> Making lua and shell files executable..."
find "${autorate_lib_path}" -type f -regex ".*\.\(lua\|sh\)" | xargs chmod +x

echo ">>> Putting config file into place..."
if [ -f "/etc/config/sqm-autorate" ]; then
    echo "!!! Warning: An sqm-autorate config file already exists. This new config file will be created as $name-NEW. Please review and merge any updates into your existing $name file."
    if [ "$is_git_proj" = true ]; then
        cp "./config/$config_file" "/etc/config/$name-NEW"
    else
        cp "/tmp/sqm-autorate-sqm-autorate-*/config/$config_file" "/etc/config/$name-NEW"
    fi
else
    if [ "$is_git_proj" = true ]; then
        cp "./config/$config_file" "/etc/config/$name"
    else
        cp "/tmp/sqm-autorate-sqm-autorate-*/config/$config_file" "/etc/config/$name"
    fi
fi

echo ">>> Putting service file into place..."
if [ "$is_git_proj" = true ]; then
    cp "./service/$service_file" "/etc/init.d/$name"
else
    cp "/tmp/sqm-autorate-sqm-autorate-*/service/$service_file" "/etc/init.d/$name"
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

echo ">>> Updating VERSION string to include: ${INSTALLATION}"
sed -i-orig "/n    /! s;^\([[:blank:]]*local[[:blank:]]*_VERSION[[:blank:]]*=[[:blank:]]*\".*\)\"[[:blank:]]*$;\1${INSTALLATION}\";" "${autorate_lib_path}/${lua_file}"

# Clean up temporary files
if [ "$is_git_proj" = false ]; then
    echo ">>> Cleaning up temporary files..."
    rm -r /tmp/sqm-autorate-install.tar.gz /tmp/sqm-autorate-sqm-autorate-*
fi

echo ">>> Installation complete, about to start configuration."

if [ ! -x $autorate_lib_path/$configure_file ]; then
    echo "${autorate_lib_path}/${configure_file} is not found or not executable"
else
    $autorate_lib_path/$configure_file
fi
