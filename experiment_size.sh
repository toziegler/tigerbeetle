#!/bin/bash

# Define ranges for leaf_size and inner_size
leaf_sizes=(2048 4096 8192 16384 32768 65536 131072 262144 524288)
inner_sizes=(2048 4096 8192 16384 32768 65536 131072 262144 524288)

# Backup the original file
cp src/lsm/btree.zig src/lsm/btree.zig.bak

for leaf_size in "${leaf_sizes[@]}"; do
    for inner_size in "${inner_sizes[@]}"; do
        # Update lines 10 and 11 in src/lsm/btree.zig
        sed -i '10s/.*/    const leaf_size = '"$leaf_size"';/' src/lsm/btree.zig
        sed -i '11s/.*/    const inner_size = '"$inner_size"';/' src/lsm/btree.zig

        # Perform your action here (e.g., compile, run tests)
        echo "Running with leaf_size=$leaf_size and inner_size=$inner_size"
        ./zig/zig build -Drelease
        sudo dd if=/dev/zero of=/dev/nvme2n1 bs=1K count=96
        sleep 5
        numactl -C 3-5 ./tigerbeetle benchmark --cache-grid=32GiB --file=/dev/nvme2n1 --query-count=0 --transfer-count=1000000

    done
done

# Restore the original file
mv src/lsm/btree.zig.bak src/lsm/btree.zig
