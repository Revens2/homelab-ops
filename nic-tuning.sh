#!/bin/bash
set -e
IFACE=$(ip route show default | awk "{print \$5}" | head -n1)
if [ -n "$IFACE" ]; then
    ip link set dev "$IFACE" txqueuelen 10000 2>/dev/null || true
    CPUS=$(printf "%x" $(( (1 << $(nproc)) - 1 )))
    for q in /sys/class/net/"$IFACE"/queues/rx-*; do
        [ -d "$q" ] && echo "$CPUS" > "$q/rps_cpus" 2>/dev/null && echo 4096 > "$q/rps_flow_cnt" 2>/dev/null || true
    done
    for q in /sys/class/net/"$IFACE"/queues/tx-*; do
        [ -d "$q" ] && echo "$CPUS" > "$q/xps_cpus" 2>/dev/null || true
    done
fi
if [ -d /sys/class/net/wt0 ]; then
    ip link set dev wt0 txqueuelen 10000 2>/dev/null || true
fi
exit 0
