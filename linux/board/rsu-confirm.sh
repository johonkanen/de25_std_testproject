#!/bin/sh
# rsu-confirm - boot confirmation for remote system update
# (plan Phase F5; ported unchanged in logic from the DE25-Nano's).
#
# Installed as /usr/sbin/rsu-confirm and started in the background by the
# first line of /etc/rc.local (linux/tools/alpine_rootfs_config.sh).
#
# U-Boot starts HPS watchdog 0 (30 s); the kernel keeps it alive until a
# program opens it (watchdog.open_timeout=120 on the kernel command line
# limits that). This opens it and pets it every 5 s while it waits for the
# system to come up healthy: the web GUI answers on localhost with the
# board id read over LWH2F ("id_ok": true in /api/board) - kernel, rootfs,
# GUI, fpga_access.py and the FPGA core all work. Healthy: logged, the RSU
# retry counter reset, and the petting goes on (a later hang still trips
# the watchdog). Not healthy within DEADLINE seconds of boot: the petting
# stops, the watchdog expires, and the SDM falls back to the next RSU image
# (the factory image) - the FPGA design's HPS IP has Rst_sdm_wd_config 2,
# "trigger remote update". On TERM (shutdown) the watchdog is disarmed.
#
# The factory image is the last resort - there is nothing below it, and it
# boots the same root filesystem, so a broken rootfs or GUI would make it
# fail too and loop. There this only reports, and pets regardless.
#
# State in /run/rsu-confirm: "waiting <image>", "confirmed <image> <s>",
# "failed <image> <s>"; every step is in the kernel log
# (dmesg | grep rsu-confirm).
WDT="${RSU_CONFIRM_WDT:-/dev/watchdog0}"
DEADLINE="${RSU_CONFIRM_DEADLINE:-300}"     # s after boot (first boot: apk add python3)
PET=5
RSU=/sys/devices/platform/stratix10-rsu.0
STATE=/run/rsu-confirm

log() { echo "rsu-confirm: $*" > /dev/kmsg; }
uptime_s() { cut -d. -f1 /proc/uptime; }
healthy() {
    wget -q -T 3 -O - http://127.0.0.1/api/board 2> /dev/null | grep -q '"id_ok": true'
}

[ -c "$WDT" ] || { log "no $WDT - nothing to confirm with"; exit 0; }
image=$(cat "$RSU/current_image" 2> /dev/null || echo unknown)
exec 3> "$WDT" || { log "cannot open $WDT"; exit 1; }
trap 'printf V >&3; exec 3>&-; log "stopped, watchdog disarmed"; exit 0' TERM INT
if rsu_client --check-running-factory 2> /dev/null | grep -q "factory image: yes"; then
    log "image $image is the factory image: reporting only, no fallback below it"
    echo "factory $image" > "$STATE"
    while ! healthy && [ "$(uptime_s)" -lt "$DEADLINE" ]; do printf . >&3; sleep "$PET"; done
    healthy && log "factory image healthy after $(uptime_s) s" ||
        log "factory image NOT healthy after $(uptime_s) s - kept running (last resort)"
    while :; do printf . >&3; sleep "$PET"; done
fi
echo "waiting $image" > "$STATE"
log "image $image: must be healthy within ${DEADLINE} s of boot, else the watchdog falls back"

while ! healthy; do
    if [ "$(uptime_s)" -ge "$DEADLINE" ]; then
        echo "failed $image $(uptime_s)" > "$STATE"
        log "image $image not healthy after $(uptime_s) s - no more petting, the SDM falls back"
        while :; do sleep 60; done          # the open fd keeps the watchdog armed
    fi
    printf . >&3
    sleep "$PET"
done

echo "confirmed $image $(uptime_s)" > "$STATE"
log "image $image healthy after $(uptime_s) s - confirmed"
rsu_client --reset-retry-counter > /dev/null 2>&1
while :; do
    printf . >&3
    sleep "$PET"
done
