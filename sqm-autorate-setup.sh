#!/bin/sh

name="sqm-autorate"

owrt_release_file="/etc/os-release"
config_file="sqm-autorate.config"
service_file="sqm-autorate.service"
lua_file="sqm-autorate.lua"
autorate_root="/usr/lib/sqm-autorate"

repo_root="https://raw.githubusercontent.com/Fail-Safe/sqm-autorate/dansbranch"

# Install the prereqs...
opkg update && opkg install luarocks lua-bit32 luaposix && luarocks install vstruct

[ -d "./.git" ] && is_git_proj=true || is_git_proj=false

if [ "$is_git_proj" = false ]; then
    # Need to curl some stuff down...
    curl -o "$config_file" "$repo_root"/"$config_file"
    curl -o "$service_file" "$repo_root"/"$service_file"
    curl -o "$lua_file" "$repo_root"/"$lua_file"
fi

if [ -f "$owrt_release_file" ]; then
    is_openwrt=$(grep "$owrt_release_file" -e '^NAME=' | awk 'BEGIN { FS = "=" } { gsub(/"/, "", $2); print $2 }')
    if [ "$is_openwrt" = "OpenWrt" ]; then
        echo "This is an OpenWrt system. Putting config file into place..."
        if [ -f "/etc/config/sqm-autorate" ]; then
            echo "  Warning: An sqm-autorate config file already exists. This new config file will be created as $name-NEW. Please review and merge any updates into your existing $name file."
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

echo "Putting sqm-autorate Lua file into place..."
mkdir -p "$autorate_root"
if [ "$is_git_proj" = true ]; then
    cp ./"$lua_file" "$autorate_root"/"$lua_file"
else
    mv ./"$lua_file" "$autorate_root"/"$lua_file"
fi

echo "Putting service file into place..."
if [ "$is_git_proj" = true ]; then
    cp ./"$service_file" /etc/init.d/"$name"
else
    mv ./"$service_file" /etc/init.d/"$name"
fi
chmod a+x /etc/init.d/"$name"

echo "All done! You can enable and start the service by executing 'service sqm-autorate enable && service sqm-autorate start'."
