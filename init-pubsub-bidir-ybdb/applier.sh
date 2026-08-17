#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# applier.sh — control the two replication lanes.
#
#   bash applier.sh start [a2b|b2a|both]     default: both
#   bash applier.sh stop  [a2b|b2a|both]
#   bash applier.sh restart [lane]
#   bash applier.sh status [lane]
#   bash applier.sh logs  <lane> [n]         default: 40 lines
#   bash applier.sh tail  <lane>
#
# A "lane" is one direction of replication: a JVM running Debezium's embedded
# engine, reading one site's replication slot and writing to the other site.
#
#   a2b   site A (127.0.0.1)  →  site B (127.0.0.11)   config: application-a2b.yml
#   b2a   site B (127.0.0.11) →  site A (127.0.0.1)    config: application-b2a.yml
#
# Two-way replication is just these two one-way lanes pointed at each other.
# There is no coordination between them and no shared state — what stops them
# echoing each other forever is the replication origin each one tags its writes
# with, and the filter each one applies to incoming changes.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

APPLIER_HOME="${APPLIER_HOME:-/home/vscode/cdc-applier}"
# Two JVMs share this container with two YugabyteDB clusters. Left unbounded,
# each JVM would size its heap at a quarter of container RAM.
APPLIER_JAVA_OPTS="${APPLIER_JAVA_OPTS:--Xms256m -Xmx768m}"

CONF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_lanes() {  # expand the lane argument into the lanes to act on
    case "${1:-both}" in
        a2b)  echo "a2b" ;;
        b2a)  echo "b2a" ;;
        both) echo "a2b b2a" ;;
        *)    echo "" ;;
    esac
}

# Log paths come from the environment so the walkthrough, this script and the
# startup script all name the same files.
_log() {
    case "$1" in
        a2b) echo "${A2B_LOG:-/tmp/cdc-applier-a2b.log}" ;;
        b2a) echo "${B2A_LOG:-/tmp/cdc-applier-b2a.log}" ;;
    esac
}
_pidf() { echo "/tmp/cdc-applier-$1.pid"; }

_jar() {
    ls "${APPLIER_HOME}"/target/*.jar 2>/dev/null | grep -v '\.original$' | head -1
}

# The JDK is put on PATH by /etc/profile.d, which only interactive shells read.
_java() {
    if command -v java >/dev/null 2>&1; then
        echo java
    else
        echo "/usr/local/jdk-${JDK_VERSION:-21}/bin/java"
    fi
}

_pid() {  # _pid <lane>
    local f; f=$(_pidf "$1")
    [ -f "${f}" ] || return 1
    local pid; pid=$(cat "${f}" 2>/dev/null)
    [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null && echo "${pid}"
}

_start_lane() {  # _start_lane <lane>
    local lane="$1" log pidf jar
    log=$(_log "${lane}"); pidf=$(_pidf "${lane}")

    if _pid "${lane}" >/dev/null; then
        echo "Lane ${lane} already running (pid $(_pid "${lane}"))."
        return 0
    fi

    jar=$(_jar)
    if [ -z "${jar}" ]; then
        echo "ERROR: no applier jar under ${APPLIER_HOME}/target/."
        echo "  The build runs in postCreateCommand. To redo it:"
        echo "    bash .devcontainer/scripts/setup-pubsub-ybdb.sh"
        return 1
    fi

    : > "${log}"
    # shellcheck disable=SC2086
    nohup "$(_java)" ${APPLIER_JAVA_OPTS} -jar "${jar}" \
        --spring.profiles.active="${lane}" \
        --spring.config.additional-location="file:${CONF_DIR}/" \
        >> "${log}" 2>&1 &
    echo $! > "${pidf}"
    echo "Lane ${lane} starting (pid $(cat "${pidf}"))  →  ${log}"

    local waited=0
    while [ "${waited}" -lt 120 ]; do
        if grep -q 'Started ChangeEventApplication' "${log}" 2>/dev/null; then
            echo "Lane ${lane} is up after ${waited}s."
            return 0
        fi
        if ! _pid "${lane}" >/dev/null; then
            echo "ERROR: lane ${lane} exited during startup. Last 30 lines:"
            tail -30 "${log}"
            return 1
        fi
        printf "\r  [%3ds] waiting for lane %s..." "${waited}" "${lane}"
        sleep 2; waited=$(( waited + 2 ))
    done
    echo ""
    echo "WARNING: lane ${lane} showed no startup banner after ${waited}s — check ${log}."
    return 1
}

_stop_lane() {  # _stop_lane <lane>
    local lane="$1" pid pidf
    pidf=$(_pidf "${lane}")
    pid=$(_pid "${lane}") || { echo "Lane ${lane} is not running."; rm -f "${pidf}"; return 0; }

    # SIGTERM so the engine stops the connector and in-flight work drains,
    # rather than leaving a transaction half-buffered.
    kill "${pid}" 2>/dev/null
    local waited=0
    while [ "${waited}" -lt 40 ] && kill -0 "${pid}" 2>/dev/null; do
        printf "\r  [%3ds] lane %s draining..." "${waited}" "${lane}"
        sleep 2; waited=$(( waited + 2 ))
    done
    kill -0 "${pid}" 2>/dev/null && kill -9 "${pid}" 2>/dev/null
    rm -f "${pidf}"
    echo ""
    echo "Lane ${lane} stopped."
}

_status_lane() {  # _status_lane <lane>
    local lane="$1" pid
    if pid=$(_pid "${lane}"); then
        printf "  %-4s RUNNING  pid %-8s config %s  log %s\n" \
            "${lane}" "${pid}" "application-${lane}.yml" "$(_log "${lane}")"
    else
        printf "  %-4s STOPPED\n" "${lane}"
    fi
}

_action="${1:-status}"
_lane_arg="${2:-both}"

case "${_action}" in
    start)
        # A→B first, matching the documented order for bringing up a two-way
        # topology. Both origins are pre-created by the startup script, so this
        # is convention rather than a hard requirement here.
        for _l in $(_lanes "${_lane_arg}"); do _start_lane "${_l}" || exit 1; done
        ;;
    stop)
        for _l in $(_lanes "${_lane_arg}"); do _stop_lane "${_l}"; done
        ;;
    restart)
        for _l in $(_lanes "${_lane_arg}"); do _stop_lane "${_l}"; done
        for _l in $(_lanes "${_lane_arg}"); do _start_lane "${_l}" || exit 1; done
        ;;
    status)
        echo "Replication lanes:"
        for _l in $(_lanes "${_lane_arg}"); do _status_lane "${_l}"; done
        ;;
    logs)
        [ "${_lane_arg}" = "both" ] && { echo "usage: bash applier.sh logs <a2b|b2a> [n]"; exit 1; }
        tail -n "${3:-40}" "$(_log "${_lane_arg}")"
        ;;
    tail)
        [ "${_lane_arg}" = "both" ] && { echo "usage: bash applier.sh tail <a2b|b2a>"; exit 1; }
        tail -f "$(_log "${_lane_arg}")"
        ;;
    *)
        echo "usage: bash applier.sh {start|stop|restart|status} [a2b|b2a|both]"
        echo "       bash applier.sh {logs|tail} <a2b|b2a> [n]"
        exit 1
        ;;
esac
