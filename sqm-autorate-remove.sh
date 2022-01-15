#!/bin/sh
#   sqm-autorate-remove.sh: removes the sqm-autorate software from an OpenWRT router
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
