#!/bin/sh

name="sqm-autorate"
autorate_root="/usr/lib/sqm-autorate"

echo ">>> Disabling and stopping service..."
/etc/init.d/"$name" disable
/etc/init.d/"$name" stop
sleep 3
echo ">>> Removing service file..."
rm -f /etc/init.d/"$name"
echo ">>> Removing sqm-autorate lib directory..."
rm -rf "$autorate_root"
echo ">>> Removing config file..."
rm -f /etc/config/"$name"

echo "!!! If you would like to remove the Lua modules which this setup previously installed, please run the following command:"
echo "!!! WARNING: Only run the following if no other applications are using these Lua modules..."
echo ""
echo "--> luarocks remove vstruct && opkg remove luarocks lua-bit32 luaposix lualanes <--"
