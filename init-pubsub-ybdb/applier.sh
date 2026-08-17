#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# applier.sh — start / stop / inspect the embedded-Debezium applier process.
#
#   bash applier.sh start        launch in the background, wait until ready
#   bash applier.sh stop         graceful shutdown (lets in-flight work drain)
#   bash applier.sh restart      stop, then start
#   bash applier.sh status       running? which pid?
#   bash applier.sh logs [n]     last n log lines (default 40)
#   bash applier.sh tail         follow the log (Ctrl-C to leave)
#
# The applier is an ordinary JVM process — there is no Kafka, no Kafka Connect
# and no separate sink connector in this pipeline. Debezium's embedded engine
# reads the publisher's replication slot in-process and hands each change event
# straight to the apply path, which writes it to the subscriber.
#
# Configuration comes from init-pubsub-ybdb/application-lab.yml via
# --spring.config.additional-location, so editing that file and restarting is
# the whole edit loop.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

APPLIER_HOME="${APPLIER_HOME:-/home/vscode/cdc-applier}"
APPLIER_PROFILE="${APPLIER_PROFILE:-lab}"
APPLIER_LOG="${APPLIER_LOG:-/tmp/cdc-applier.log}"
APPLIER_PID="${APPLIER_PID:-/tmp/cdc-applier.pid}"

# The exercise directory holds application-${APPLIER_PROFILE}.yml. Resolve it
# from this script's own location so the command works from anywhere.
CONF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_jar() {
    ls "${APPLIER_HOME}"/target/*.jar 2>/dev/null | grep -v '\.original$' | head -1
}

# The setup script puts the JDK on PATH via /etc/profile.d, which only
# interactive shells read. Fall back to the known install path so this works
# from a plain `bash applier.sh` too.
_java() {
    if command -v java >/dev/null 2>&1; then
        echo java
    else
        echo "/usr/local/jdk-${JDK_VERSION:-21}/bin/java"
    fi
}

_pid() {
    [ -f "${APPLIER_PID}" ] || return 1
    local pid
    pid=$(cat "${APPLIER_PID}" 2>/dev/null)
    [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null && echo "${pid}"
}

_start() {
    if _pid >/dev/null; then
        echo "Applier already running (pid $(_pid))."
        return 0
    fi

    local jar
    jar=$(_jar)
    if [ -z "${jar}" ]; then
        echo "ERROR: no applier jar under ${APPLIER_HOME}/target/."
        echo "  The build runs in postCreateCommand. To redo it:"
        echo "    bash .devcontainer/scripts/setup-pubsub-ybdb.sh"
        return 1
    fi

    : > "${APPLIER_LOG}"
    nohup "$(_java)" -jar "${jar}" \
        --spring.profiles.active="${APPLIER_PROFILE}" \
        --spring.config.additional-location="file:${CONF_DIR}/" \
        >> "${APPLIER_LOG}" 2>&1 &
    echo $! > "${APPLIER_PID}"
    echo "Applier starting (pid $(cat "${APPLIER_PID}"))  →  ${APPLIER_LOG}"

    # Ready = Spring reports the context started. The snapshot begins straight
    # after and is watched separately, by counting rows on the subscriber.
    local waited=0
    while [ "${waited}" -lt 120 ]; do
        if grep -q 'Started ChangeEventApplication' "${APPLIER_LOG}" 2>/dev/null; then
            echo "Applier is up after ${waited}s."
            return 0
        fi
        if ! _pid >/dev/null; then
            echo "ERROR: the applier exited during startup. Last 30 lines:"
            tail -30 "${APPLIER_LOG}"
            return 1
        fi
        printf "\r  [%3ds] waiting for the applier to start..." "${waited}"
        sleep 2; waited=$(( waited + 2 ))
    done
    echo ""
    echo "WARNING: no startup banner after ${waited}s — check ${APPLIER_LOG}."
    return 1
}

_stop() {
    local pid
    pid=$(_pid) || { echo "Applier is not running."; rm -f "${APPLIER_PID}"; return 0; }

    # SIGTERM, not SIGKILL: the engine stops the connector and the apply path
    # drains in-flight work rather than leaving a transaction half-buffered.
    kill "${pid}" 2>/dev/null
    local waited=0
    while [ "${waited}" -lt 40 ] && kill -0 "${pid}" 2>/dev/null; do
        printf "\r  [%3ds] draining..." "${waited}"
        sleep 2; waited=$(( waited + 2 ))
    done
    kill -0 "${pid}" 2>/dev/null && kill -9 "${pid}" 2>/dev/null
    rm -f "${APPLIER_PID}"
    echo ""
    echo "Applier stopped."
}

case "${1:-status}" in
    start)   _start ;;
    stop)    _stop ;;
    restart) _stop; _start ;;
    status)
        if pid=$(_pid); then
            echo "Applier is RUNNING (pid ${pid})"
            echo "  jar     : $(_jar)"
            echo "  profile : ${APPLIER_PROFILE}"
            echo "  config  : ${CONF_DIR}/application-${APPLIER_PROFILE}.yml"
            echo "  log     : ${APPLIER_LOG}"
        else
            echo "Applier is STOPPED"
        fi
        ;;
    logs)    tail -n "${2:-40}" "${APPLIER_LOG}" ;;
    tail)    tail -f "${APPLIER_LOG}" ;;
    *)
        echo "usage: bash applier.sh {start|stop|restart|status|logs [n]|tail}"
        exit 1
        ;;
esac
