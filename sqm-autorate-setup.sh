#!/bin/sh

name="sqm-autorate"

owrt_release_file="/etc/os-release"
config_file="sqm-autorate.config"
service_file="sqm-autorate.service"
lua_file="sqm-autorate.lua"
autorate_root="/usr/lib/sqm-autorate"

repo_root="https://raw.githubusercontent.com/Fail-Safe/sqm-autorate/experimental"

check_for_sqm() {
    # Check first to see if SQM is installed and if not, offer to install it...
    if [ "$(opkg list-installed luci-app-sqm | wc -l)" = "0" ]; then
        # SQM is missing, let's prompt to install it...
        echo "!!! SQM (luci-app-sqm) is missing from your system and is required for sqm-autorate to function."
        read -p ">> Would you like to install SQM (luci-app-sqm) now? (y/n) " install_sqm
        install_sqm=$(echo "$install_sqm" | awk '{ print tolower($0) }')
        if [ "$install_sqm" = "y" ] || [ "$install_sqm" = "yes" ]; then
            opkg install luci-app-sqm || echo "!!! An error occurred while trying to install luci-app-sqm. Please try again."
            exit 1
        else
            # We have to bail out if we don't have luci-app-sqm on OpenWrt...
            echo "> You must install SQM (luci-app-sqm) before using sqm-autorate. Cannot continue. Exiting."
            exit 1
        fi
    else
        echo "> Congratulations! You already have SQM (luci-app-sqm) installed. We can proceed with the sqm-autorate setup now..."
    fi
}

[ -d "./.git" ] && is_git_proj=true || is_git_proj=false

if [ "$is_git_proj" = false ]; then
    # Need to curl some stuff down...
    echo ">>> Pulling down sqm-autorate operational files..."
    curl -o "$config_file" "$repo_root"/"$config_file"
    curl -o "$service_file" "$repo_root"/"$service_file"
    curl -o "$lua_file" "$repo_root"/"$lua_file"
else
    echo "> Since this is a Git project, local files will be used and will be COPIED into place instead of MOVED..."
fi

if [ -f "$owrt_release_file" ]; then
    is_openwrt=$(grep "$owrt_release_file" -e '^NAME=' | awk 'BEGIN { FS = "=" } { gsub(/"/, "", $2); print $2 }')
    if [ "$is_openwrt" = "OpenWrt" ]; then
        echo ">> This is an OpenWrt system."
        echo ">>> Refreshing package cache. This may take a few moments..."
        opkg update -V0
        check_for_sqm

        # Install the sqm-autorate prereqs...
        echo ">>> Installing prerequisite packages via opkg..."
        opkg install -V0 luajit luarocks lua-bit32 luaposix && luarocks install vstruct

        echo ">>> Putting config file into place..."
        if [ -f "/etc/config/sqm-autorate" ]; then
            echo "!!! Warning: An sqm-autorate config file already exists. This new config file will be created as $name-NEW. Please review and merge any updates into your existing $name file."
            if [ "$is_git_proj" = true ]; then
                cp ./"$config_file" /etc/config/"$name"-NEW
            else
                mv ./"$config_file" /etc/config/"$name"-NEW
            fi
        else
            if [ "$is_git_proj" = true ]; then
                cp ./"$config_file" /etc/config/"$name"
            else
                mv ./"$config_file" /etc/config/"$name"
            fi
        fi
    fi
fi

echo ">>> Putting sqm-autorate Lua file into place..."
mkdir -p "$autorate_root"
if [ "$is_git_proj" = true ]; then
    cp ./"$lua_file" "$autorate_root"/"$lua_file"
else
    mv ./"$lua_file" "$autorate_root"/"$lua_file"
fi

echo ">>> Putting service file into place..."
if [ "$is_git_proj" = true ]; then
    cp ./"$service_file" /etc/init.d/"$name"
else
    mv ./"$service_file" /etc/init.d/"$name"
fi
chmod a+x /etc/init.d/"$name"

echo "> All done! You can enable and start the service by executing 'service sqm-autorate enable && service sqm-autorate start'."
