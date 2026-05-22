#!/usr/bin/env bash
# verify_v_hand.sh -- run yosys elaborate/stat on each hand-flattened module.
# Usage: bash verify_v_hand.sh [module1 module2 ...]
# If no args, verifies every .v in v_hand/.
set -e
export PATH="$(echo "$PATH" | tr ':' '\n' | grep -v '^/mnt/' | paste -sd:)"
YOSYS=/nix/store/9r0bh7sp051dpm8km8bqlb028anpd3v3-yosys/bin/yosys

cd "$(dirname "$0")"

if [ $# -eq 0 ]; then
    mods=$(ls v_hand/*.v 2>/dev/null | xargs -n1 basename | sed 's/\.v$//')
else
    mods="$@"
fi

for m in $mods; do
    echo "==================== $m ===================="
    # Read every .v in v_hand/ so cross-module references resolve, then
    # restrict the hierarchy/stat to the module under test.
    "$YOSYS" -p "read_verilog v_hand/*.v; hierarchy -check -top ${m}; stat" \
        2>&1 | tail -12
done
