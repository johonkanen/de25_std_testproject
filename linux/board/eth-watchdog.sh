#!/bin/sh
# eth-watchdog [GATEWAY] - bring eth0 back when it stops passing traffic.
#
# Installed as /usr/sbin/eth-watchdog and started (respawned) from inittab
# by linux/tools/alpine_rootfs_config.sh.
#
# Copied from the DE25-Nano, where about 1 in 5 warm reboots (none seen
# after a power-on) eth0 came up with link but passed no traffic, in one
# of two ways (2026-10-17):
#   - the RX DMA stops: SMMU F_TRANSLATION faults on the EMAC's descriptor
#     rings at the first open, then a fatal bus error; frames arrive at the
#     MAC and overflow its FIFO (rx_packets stays 0)
#   - transmitted frames are lost after the MAC: the MAC counts them, the
#     host never sees the ARP replies
# Not the old kernel's DMA running across the reboot (stopping eth0 before
# `reboot` did not help), and not the PHY delays (rgmii-id, as U-Boot uses,
# breaks the link every time - the board traces carry the delays). Both
# forms clear with eth0 down/up, which this does - the cause is still open
# (docs/linux_boot.md, Known gaps). A down/up can land in the stall too
# (seen once): the next check bounces again.
#
# The gateway is the probe: pinged every 5 s for the first two minutes
# after boot, every 30 s after that; three misses in a row bounce eth0 and
# put back the default route the board had (a link down flushes it).
# Every bounce is logged to the kernel log (dmesg | grep eth-watchdog).
GW="${1:-$(ip route | awk '/^default/ {print $3; exit}')}"
[ -n "$GW" ] || { echo "eth-watchdog: no gateway" > /dev/kmsg; sleep 60; exit 1; }

log() { echo "eth-watchdog: $*" > /dev/kmsg; }

misses=0
bounces=0
start=$(cut -d. -f1 /proc/uptime)
log "watching eth0 via $GW"
while true; do
    if ping -c 1 -W 2 "$GW" > /dev/null 2>&1; then
        [ "$misses" -ge 3 ] || [ "$misses" -eq 0 ] || log "$GW answers again after $misses misses"
        misses=0
    else
        misses=$((misses + 1))
    fi
    if [ "$misses" -ge 3 ]; then
        bounces=$((bounces + 1))
        rx=$(cat /sys/class/net/eth0/statistics/rx_packets)
        tx=$(cat /sys/class/net/eth0/statistics/tx_packets)
        log "no answer from $GW 3 times (rx_packets $rx, tx_packets $tx) - eth0 down/up (#$bounces)"
        via=$(ip route | awk '/^default/ {print $3; exit}')
        ip link set eth0 down
        ip link set eth0 up
        sleep 8                         # the PHY renegotiates (~3 s)
        [ -n "$via" ] && ip route add default via "$via" dev eth0 2> /dev/null
        misses=0
    fi
    now=$(cut -d. -f1 /proc/uptime)
    if [ $((now - start)) -lt 120 ]; then sleep 5; else sleep 30; fi
done
