#!/bin/sh

# Copy interesting sqm-autorate files from OpenWrt to ~/Desktop
# 
# Run the getstats.sh script to create /tmp/openwrtscripts.txt
# Compress it and the three /tmp/sqm-* files then copy (over SSH)
# to a result file with a timestamp in the name
# 
# Usage:
#    sh retrievestats.sh root@192.168.1.1 # login on OpenWrt
# 
# or just copy/paste the lines below into the command line, substituting root@ip-address for "$1"
#    
# Output is a file on ~/Desktop named
#    openwrtstats-yyyy-mm-dd-hhmmss.gz

ssh "$1" \
"/usr/lib/sqm-autorate/getstats.sh > /dev/null; \
cd /tmp; \
tar -cvzf - \
	openwrtstats.txt \
	sqm-autorate.csv \
	sqm-autorate.log \
	sqm-speedhist.csv" \
> ~/Desktop/openwrtstats-$(date "+%F-%H%M%S").gz

# Notes:
# - The script tar's and compresses on the fly so it doesn't
#     consume (much) file system space on the OpenWrt target.
# - The ssh command executes the getstats.sh script to get the
#     current state of the router. Note that this will overwrite
#     previously-saved copies of /tmp/openwrtstats.txt
# - The `> /dev/null` prevents the getstats.sh script's output
#     from polluting the resulting .gz file
