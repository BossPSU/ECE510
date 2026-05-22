#!/usr/bin/env bash
cd /mnt/c/Users/david/OneDrive/Documents/psu/510/GitHub/project/sv_v_conversion/synth
echo "=== completed modules so far ==="
printf "%-32s %12s %12s\n" "module" "cells" "area_um2"
for d in per_module/*/; do
    top=$(basename "$d")
    if [ -f "$d/stat.rpt" ]; then
        cells=$(grep -E "Number of cells:" "$d/stat.rpt" | tail -1 | awk '{print $4}')
        area=$(grep -E "Chip area for module" "$d/stat.rpt" | tail -1 | awk '{print $NF}')
        printf "%-32s %12s %12s\n" "$top" "${cells:-?}" "${area:-?}"
    else
        printf "%-32s %12s\n" "$top" "(active)"
    fi
done
echo ""
echo "=== currently running ==="
ps -eo pid,etime,rss,comm | grep -E "yosys|abc" | grep -v grep | head -5
echo ""
echo "=== mem ==="
free -h | head -3
