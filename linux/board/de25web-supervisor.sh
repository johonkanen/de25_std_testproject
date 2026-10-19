#!/bin/sh
# de25web-supervisor.sh - runs the DE25-Standard web GUI and keeps a bad
# release from sticking. Started by init (/etc/inittab ::respawn:) and
# installed once, outside every release (linux/tools/install_webapp.py), so
# no GUI update can break the thing that rolls GUI updates back.
#
# (Ported unchanged in logic from the DE25-Nano's.) A release is three
# processes, started in this order from current/ and each restarted when it
# exits:
#   fpga_access.py   the only one mapping /dev/mem; RUN/fpga.sock
#   temp_control.py  the die temperature loop;      RUN/control.sock
#   fpga_web.py      the HTTP server; its exit (an update, a rollback, a
#                    crash) stops the other two and starts current/ afresh
# A release without fpga_access.py (only the Nano had those) runs
# fpga_web.py alone.
#
# Layout under BASE (see linux/webapp/README.md):
#   releases/<name>/  current -> releases/<name>  previous -> releases/<name>
#   pending           the release on test (written by POST /api/update)
#   control.json      the temperature loop's settings (kept across releases)
#
# A release on test is reverted to "previous" when
#   - it is still unconfirmed TEST_SECONDS after it first started,
#   - any of its processes exits MAX_FAILS times (together) while on test, or
#   - the board restarts while it is on test (this script starting with a
#     pending file means the test never finished).
# Confirmation is POST /api/update/confirm - the GUI page does it once it
# has loaded and read the board, and the server refuses it unless the FPGA
# access and the temperature control processes answer; deploy_web.py
# confirms after its own checks.
#
# The fan while processes come and go: the MAX6650 holds the last speed. A
# temperature controller that stops writing for 10 s gets the fan raised to
# 4000 rpm by fpga_access.py (its lease). The MAX6650 has no thermal
# fail-safe of its own (plan §5.17): with fpga_access.py down too, nothing
# raises the fan - this script restarts it within a second.
BASE="${DE25WEB_BASE:-/opt/de25web}"
PORT="${DE25WEB_PORT:-80}"
PYTHON="${DE25WEB_PYTHON:-python3}"
RUN="${DE25WEB_RUN:-/run/de25web}"
TEST_SECONDS="${DE25WEB_TEST_SECONDS:-120}"
MAX_FAILS="${DE25WEB_MAX_FAILS:-3}"
LOG="${BASE}/supervisor.log"
EXTRA_ARGS="${DE25WEB_ARGS:-}"          # for fpga_web.py; "--sim" goes to all three
SIM=""
case " ${EXTRA_ARGS} " in *" --sim "*) SIM="--sim" ;; esac

cd "${BASE}" || exit 1
mkdir -p "${RUN}"
export DE25WEB_BASE="${BASE}" DE25WEB_RUN="${RUN}"

log() { echo "$(date '+%F %T') $*" >> "${LOG}"; }
uptime_s() { cut -d. -f1 /proc/uptime; }
current() { basename "$(readlink current)"; }
# true while release $1 is the one on test (pending names it)
on_test() { [ -n "$1" ] && [ -f pending ] && [ "$(cat pending)" = "$1" ]; }
alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }

revert() {
    prev="$(readlink previous)"
    if [ -z "${prev}" ]; then
        log "revert wanted ($1) but there is no previous release - keeping $(current)"
        rm -f pending
        return
    fi
    bad="$(current)"
    # -n: replace the link itself, not create one inside the directory it
    # points at (no mv -T in busybox; the processes are stopped here anyway)
    ln -sfn "${prev}" current
    ln -sfn "releases/${bad}" previous
    rm -f pending
    log "reverted ${bad} -> $(current): $1"
}

# ---- the processes ---------------------------------------------------------
apid=""; cpid=""; wpid=""

start_access() {
    "${PYTHON}" "${BASE}/current/fpga_access.py" --run "${RUN}" ${SIM} >> "${BASE}/access.log" 2>&1 &
    apid=$!; echo "${apid}" > "${RUN}/fpga_access.pid"
    # the others need its socket: wait for it (a few seconds at most)
    i=0
    while [ ${i} -lt 50 ] && alive "${apid}"; do
        "${PYTHON}" "${BASE}/current/fpga_access.py" --run "${RUN}" --client ping >/dev/null 2>&1 && return 0
        sleep 0.2; i=$((i + 1))
    done
    log "fpga_access.py not answering yet"
}

start_control() {
    "${PYTHON}" "${BASE}/current/temp_control.py" --run "${RUN}" --config "${BASE}/control.json" ${SIM} \
        >> "${BASE}/control.log" 2>&1 &
    cpid=$!; echo "${cpid}" > "${RUN}/temp_control.pid"
}

start_web() {
    # shellcheck disable=SC2086
    "${PYTHON}" "${BASE}/current/fpga_web.py" --port "${PORT}" --base "${BASE}" --run "${RUN}" ${EXTRA_ARGS} \
        >> "${BASE}/server.log" 2>&1 &
    wpid=$!; echo "${wpid}" > "${RUN}/fpga_web.pid"
}

start_legacy_web() {        # a release from before the split: maps /dev/mem itself
    # shellcheck disable=SC2086
    "${PYTHON}" "${BASE}/current/fpga_web.py" --port "${PORT}" --base "${BASE}" ${EXTRA_ARGS} \
        >> "${BASE}/server.log" 2>&1 &
    wpid=$!; echo "${wpid}" > "${RUN}/fpga_web.pid"
}

stop() {        # stop pid $1 (TERM, then KILL after 3 s)
    alive "$1" || return 0
    kill "$1" 2>/dev/null
    i=0
    while alive "$1" && [ ${i} -lt 15 ]; do sleep 0.2; i=$((i + 1)); done
    alive "$1" && kill -9 "$1" 2>/dev/null
    wait "$1" 2>/dev/null
}

stop_all() {    # web first (no new requests), then the loop, then the registers
    stop "${wpid}"; stop "${cpid}"; stop "${apid}"
    wpid=""; cpid=""; apid=""
    rm -f "${RUN}"/*.pid
}

# processes left by a supervisor that was killed (init respawns this one)
for f in "${RUN}"/*.pid; do
    [ -f "${f}" ] || continue
    p="$(cat "${f}")"
    if alive "${p}" && grep -q "${BASE}/current/" "/proc/${p}/cmdline" 2>/dev/null; then
        kill "${p}" 2>/dev/null && log "stopped a leftover $(basename "${f}" .pid) (${p})"
    fi
    rm -f "${f}"
done
pkill -f "${BASE}/current/fpga_web.py" 2>/dev/null     # a pre-1.3.0 supervisor's server

trap 'log "supervisor stopping"; stop_all; exit 0' TERM INT HUP

# trim the logs now and then (the rootfs is an SD card)
for f in "${LOG}" "${BASE}/server.log" "${BASE}/access.log" "${BASE}/control.log"; do
    [ -f "${f}" ] && [ "$(wc -c < "${f}")" -gt 200000 ] && tail -n 500 "${f}" > "${f}.1" && mv -f "${f}.1" "${f}"
done

if [ -f pending ]; then
    revert "the board restarted while $(cat pending) was on test"
fi

test_rel=""
test_t0=0
fails=0
while :; do
    rel="$(current)"
    if on_test "${rel}"; then
        if [ "${test_rel}" != "${rel}" ]; then
            test_rel="${rel}"; test_t0="$(uptime_s)"; fails=0
            log "testing ${rel} for ${TEST_SECONDS} s"
        fi
    else
        test_rel=""
    fi

    if [ -f "${BASE}/current/fpga_access.py" ]; then
        split=1
        log "starting ${rel}: fpga_access, temp_control, fpga_web"
        start_access; start_control; start_web
    else
        split=""
        log "starting ${rel} (single process)"
        start_legacy_web
    fi

    reverted=""
    while alive "${wpid}"; do
        sleep 1
        # confirmed (pending gone), or replaced by a newer upload: no
        # longer this release's test - the next start picks up a new one
        on_test "${test_rel}" || test_rel=""
        if [ -n "${split}" ]; then
            for which in access control; do
                if [ "${which}" = access ]; then p="${apid}"; else p="${cpid}"; fi
                alive "${p}" && continue
                wait "${p}" 2>/dev/null; rc=$?
                if [ -n "${test_rel}" ]; then
                    fails=$((fails + 1))
                    log "${which} of ${test_rel} exited (${rc}) while on test, ${fails}/${MAX_FAILS}"
                else
                    log "${which} exited (${rc}), restarting it"
                fi
                if [ "${which}" = access ]; then start_access; else start_control; fi
            done
            if [ -n "${test_rel}" ] && [ "${fails}" -ge "${MAX_FAILS}" ]; then
                stop_all
                revert "its processes exited ${fails} times while on test"
                test_rel=""; reverted=1
                break
            fi
        fi
        if [ -n "${test_rel}" ] && [ $(( $(uptime_s) - test_t0 )) -ge "${TEST_SECONDS}" ]; then
            stop_all
            revert "not confirmed within ${TEST_SECONDS} s"
            test_rel=""; reverted=1
            break
        fi
    done
    if [ -n "${reverted}" ]; then sleep 1; continue; fi
    wait "${wpid}" 2>/dev/null
    rc=$?
    stop_all                # the next round starts whatever current/ is now

    if on_test "${test_rel}" && [ "$(current)" = "${test_rel}" ]; then
        fails=$((fails + 1))
        log "${test_rel} exited (${rc}) while on test, ${fails}/${MAX_FAILS}"
        if [ "${fails}" -ge "${MAX_FAILS}" ]; then
            revert "exited ${fails} times while on test"
            test_rel=""
        fi
    elif [ "${rc}" -ne 0 ]; then
        log "$(current) exited (${rc})"
    fi
    sleep 1
done
