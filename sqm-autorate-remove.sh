#!/bin/sh

name="sqm-autorate"
autorate_lib_path="/usr/lib/sqm-autorate"

echo ">>> Disabling and stopping service..."
/etc/init.d/"$name" disable
/etc/init.d/"$name" stop
sleep 3
echo ">>> Removing service file..."
rm -f /etc/init.d/"$name"
echo ">>> Removing sqm-autorate lib directory..."
rm -rf "$autorate_lib_path"
echo ">>> Removing config file..."
rm -f /etc/config/"$name"
echo ">>> Removing sqm-autorate files from /tmp..."
rm -f /tmp/sqm-autorate.log /tmp/sqm-autorate.csv /tmp/sqm-speedhist.csv

echo "!!! If you would like to remove the Lua modules which this setup previously installed, please run the following command:"
echo "!!! WARNING: Only run the following if no other applications are using these Lua modules..."
echo ""
echo "--> luarocks remove vstruct && opkg remove luarocks lua-bit32 luaposix lualanes lua-argparse <--"
