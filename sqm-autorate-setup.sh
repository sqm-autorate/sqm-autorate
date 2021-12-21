#!/bin/sh

owrt_release_file="/etc/os-release"
config_file="sqm-autorate.config"
service_file="sqm-autorate"
lua_file="sqm-autorate.lua"
autorate_root="/usr/lib/sqm-autorate"

if [ -f "$owrt_release_file" ]; then
    is_openwrt=$(grep "$owrt_release_file" -e '^NAME=' | awk 'BEGIN { FS = "=" } { gsub(/"/, "", $2); print $2 }')
    if [ "$is_openwrt" = "OpenWrt" ]; then
        echo "This is an OpenWrt system. Putting config file into place..."
        if [ -f "/etc/config/$config_file" ]; then
            echo "  Warning: An sqm-autorate config file already exists. This new config file will be created as $config_file-NEW. Please review and merge any updates into your existing $config_file file."
            mv ./"$config_file" /etc/config/"$config_file"-NEW
        else
            mv ./"$config_file" /etc/config/"$config_file"
        fi
    fi
fi

echo "Putting sqm-autorate Lua file into place..."
mkdir -p "$autorate_root"
mv ./"$lua_file" "$autorate_root"/"$lua_file"

echo "Putting service file into place..."
mv ./"$service_file" /etc/init.d/"$service_file"

echo "All done! You can enable and start the service by executing 'service sqm-autorate enable && service sqm-autorate start'."
