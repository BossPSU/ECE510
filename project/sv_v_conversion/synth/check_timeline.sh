#!/usr/bin/env bash
cd /mnt/c/Users/david/OneDrive/Documents/psu/510/GitHub/project/sv_v_conversion/synth
echo "=== completion timestamps (sorted) ==="
for d in per_module/*/; do
    top=$(basename "$d")
    if [ -f "$d/stat.rpt" ]; then
        ts=$(stat -c '%y' "$d/stat.rpt" 2>/dev/null | cut -d'.' -f1)
        echo "$ts  $top"
    fi
done | sort
echo ""
echo "=== modules without stat.rpt yet ==="
for d in per_module/*/; do
    top=$(basename "$d")
    if [ ! -f "$d/stat.rpt" ]; then
        ts=$(stat -c '%y' "$d" 2>/dev/null | cut -d'.' -f1)
        echo "  $ts  $top  (dir created)"
    fi
done | sort
echo ""
echo "=== currently running ==="
ps -eo pid,etime,rss,comm | grep -E "yosys|abc" | grep -v grep | head -5
echo ""
free -h | head -3
