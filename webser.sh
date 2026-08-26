#!/usr/bin/env bash
# =============================================================================
# webser.sh — Local Web Server Manager for Termux
# Version: 1.1 (Stable Release)
# =============================================================================
# Purpose:
#   A modular, production-quality web server manager designed for Termux.
#   Exposes clean shell commands: webstart, webstop, weblist, webstatus,
#   webshow, weblogs, webclearlogs, webclear, webhelp.
#
# Usage:
#   Source this file or symlink its command functions into your PATH.
#   Recommended: add "source /path/to/webser.sh" in your ~/.bashrc or ~/.zshrc
#
# Author: cyansire
# License: MIT
# =============================================================================

# ---------------------------------------------------------------------------
# GLOBAL CONSTANTS
# ---------------------------------------------------------------------------

readonly WERSER_VERSION="1.1"

# Runtime config and state directory
readonly WERSER_CONFIG_DIR="${HOME}/.config/webserver"

# Log directory
readonly WERSER_LOG_DIR="${HOME}/.local/share/webserver/logs"

# Runtime database file (tracks running servers)
# Format (TSV, one line per server):
#   PORT  PID  BACKEND  DIRECTORY  LOGFILE  STARTED_EPOCH
readonly WERSER_DB="${WERSER_CONFIG_DIR}/servers.db"

# Lock directory — mkdir is atomic, used to serialise concurrent DB writes
readonly WERSER_LOCK="${WERSER_CONFIG_DIR}/.db.lock"

# Crash log — appended whenever a tracked server dies unexpectedly
readonly WERSER_CRASH_LOG="${WERSER_LOG_DIR}/crashes.log"

# Stores the last successfully loaded version string — used for config migration
readonly WERSER_VERSION_FILE="${WERSER_CONFIG_DIR}/version"

# Session-level guard: prevents _config_migrate from running more than once
# per process even if _init_dirs is called multiple times.
_WEBSER_MIGRATED=0

# ---------------------------------------------------------------------------
# ANSI COLOUR PALETTE  (cyber/terminal style)
# ---------------------------------------------------------------------------

C_RESET=$'\033[0m'
C_BLACK=$'\033[0;30m'
C_RED=$'\033[0;31m'
C_GREEN=$'\033[0;32m'
C_YELLOW=$'\033[0;33m'
C_BLUE=$'\033[0;34m'
C_MAGENTA=$'\033[0;35m'
C_CYAN=$'\033[0;36m'
C_WHITE=$'\033[0;37m'
C_BOLD=$'\033[1m'
C_BRED=$'\033[1;31m'
C_BGREEN=$'\033[1;32m'
C_BYELLOW=$'\033[1;33m'
C_BBLUE=$'\033[1;34m'
C_BMAGENTA=$'\033[1;35m'
C_BCYAN=$'\033[1;36m'
C_BWHITE=$'\033[1;37m'
C_DIM=$'\033[2m'

# Disable colours when output is not a terminal
if [[ ! -t 1 ]]; then
    C_RESET="" C_BLACK="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE=""
    C_MAGENTA="" C_CYAN="" C_WHITE="" C_BOLD="" C_BRED="" C_BGREEN=""
    C_BYELLOW="" C_BBLUE="" C_BMAGENTA="" C_BCYAN="" C_BWHITE="" C_DIM=""
fi

# ---------------------------------------------------------------------------
# OUTPUT HELPERS
# ---------------------------------------------------------------------------

_info() { printf "${C_BCYAN}[*]${C_RESET} %s\n"    "$*"; }
_ok()   { printf "${C_BGREEN}[✓]${C_RESET} %s\n"   "$*"; }
_warn() { printf "${C_BYELLOW}[!]${C_RESET} %s\n"  "$*" >&2; }
_err()  { printf "${C_BRED}[✗]${C_RESET} %s\n"     "$*" >&2; }

# Section header (pure-bash repeat — no subshell/seq needed)
_header() {
    local title="$1" width=60 line=""
    local i; for (( i=0; i<width; i++ )); do line+="─"; done
    printf "\n${C_BBLUE}%s${C_RESET}\n"          "$line"
    printf "${C_BBLUE}  %-${width}s${C_RESET}\n" "$title"
    printf "${C_BBLUE}%s${C_RESET}\n"            "$line"
}

# Key-value detail row
_detail() { printf "  ${C_BCYAN}%-18s${C_RESET} %s\n" "$1" "$2"; }

# ---------------------------------------------------------------------------
# INITIALISATION
# ---------------------------------------------------------------------------

_init_dirs() {
    mkdir -p "${WERSER_CONFIG_DIR}" || {
        _err "Cannot create config directory: ${WERSER_CONFIG_DIR}"
        return 1
    }
    mkdir -p "${WERSER_LOG_DIR}" || {
        _err "Cannot create log directory: ${WERSER_LOG_DIR}"
        return 1
    }
    if [[ ! -f "${WERSER_DB}" ]]; then
        touch "${WERSER_DB}" || {
            _err "Cannot create runtime database: ${WERSER_DB}"
            return 1
        }
    fi
    # Run config migration on every init (cheap — exits early if version matches)
    _config_migrate
}

# ---------------------------------------------------------------------------
# VERSION HELPERS  (v0.9)
# ---------------------------------------------------------------------------

# _version_lt v1 v2 — returns 0 (true) if v1 is strictly less than v2
_version_lt() {
    local IFS='.'
    local -a a=($1) b=($2)
    local i
    for (( i=0; i < ${#b[@]}; i++ )); do
        (( ${a[i]:-0} < ${b[i]:-0} )) && return 0
        (( ${a[i]:-0} > ${b[i]:-0} )) && return 1
    done
    return 1  # equal → not less-than
}

# ---------------------------------------------------------------------------
# CONFIG MIGRATION  (v0.9)
# ---------------------------------------------------------------------------

# Called from _init_dirs after directories exist.
# Reads the stored version, runs any needed migrations, writes current version.
# The _WEBSER_MIGRATED guard prevents multiple runs per process session.
_config_migrate() {
    # De-duplicate: only run once per shell session / process
    (( _WEBSER_MIGRATED )) && return 0

    local stored_ver=""
    [[ -f "${WERSER_VERSION_FILE}" ]] && stored_ver=$(cat "${WERSER_VERSION_FILE}" 2>/dev/null || true)

    # Nothing to do when already on this version
    if [[ "$stored_ver" == "${WERSER_VERSION}" ]]; then
        _WEBSER_MIGRATED=1
        return 0
    fi

    # --- Migration hooks — ordered oldest-to-newest ---
    # DB schema gained a 7th field (FILENAME) in v1.0. Old entries without
    # it are handled gracefully — _db_get returns "" for a missing field.
    # Pattern for future versions:
    #   _version_lt "$stored_ver" "1.1" && _migrate_to_1_1

    # Write the current version to disk
    printf '%s\n' "${WERSER_VERSION}" > "${WERSER_VERSION_FILE}" || true

    if [[ -n "$stored_ver" ]]; then
        _info "Config updated: v${stored_ver} → v${WERSER_VERSION}"
    fi

    _WEBSER_MIGRATED=1
}

# ---------------------------------------------------------------------------
# CORE DEPENDENCY CHECK  (v0.7)
# ---------------------------------------------------------------------------

# Verify that essential POSIX tools and a suitable Bash version are present.
# Called once from _webser_main before dispatching any command.
_check_core_deps() {
    local missing=0 cmd
    for cmd in grep awk cut mktemp date kill; do
        if ! command -v "$cmd" &>/dev/null; then
            _warn "Missing core tool: ${C_BWHITE}${cmd}${C_RESET}"
            (( missing++ ))
        fi
    done
    if (( missing > 0 )); then
        _err "webser requires core POSIX tools. Try: ${C_BYELLOW}pkg install busybox${C_RESET}"
        return 1
    fi
    if (( BASH_VERSINFO[0] < 4 )); then
        _err "webser requires Bash 4.0+  (found: ${BASH_VERSION})"
        _warn "Upgrade with: ${C_BYELLOW}pkg install bash${C_RESET}"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# DEPENDENCY DETECTION
# ---------------------------------------------------------------------------

declare -A _BACKEND_INSTALL=(
    [python]="pkg install python"
    [python3]="pkg install python"
    [flask]="pip install flask  (after: pkg install python)"
    [busybox]="pkg install busybox"
    [php]="pkg install php"
    [node]="pkg install nodejs"
    [http-server]="npm install -g http-server  (after: pkg install nodejs)"
)

_has_binary() { command -v "$1" &>/dev/null; }

_has_python_module() {
    local module="$1"
    if _has_binary python3; then
        python3 -c "import ${module}" &>/dev/null
    elif _has_binary python; then
        python  -c "import ${module}" &>/dev/null
    else
        return 1
    fi
}

_missing_dep() {
    local dep="$1"
    local hint="${_BACKEND_INSTALL[$dep]:-}"
    _err "Missing dependency: ${C_BWHITE}${dep}${C_RESET}"
    if [[ -n "$hint" ]]; then
        printf "  ${C_DIM}Install using:${C_RESET}\n"
        printf "    ${C_BYELLOW}%s${C_RESET}\n" "$hint"
    fi
}

_require_binary() {
    _has_binary "$1" || { _missing_dep "$1"; return 1; }
}

# ---------------------------------------------------------------------------
# PORT VALIDATION
# ---------------------------------------------------------------------------

_validate_port() {
    local port="$1"
    if [[ -z "$port" ]]; then
        _err "No port specified."
        return 1
    fi
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        _err "Invalid port: '${port}'. Must be a number (1–65535)."
        return 1
    fi
    if (( port < 1 || port > 65535 )); then
        _err "Invalid port: '${port}'. Must be between 1 and 65535."
        return 1
    fi
}

_check_privileged_port() {
    local port="$1"
    if (( port < 1024 )); then
        if ! _is_rooted; then
            _err "Port ${port} is privileged (< 1024)."
            _warn "Android blocks ports below 1024 on non-rooted devices."
            _warn "Use a port ≥ 1024, or root your device."
            return 1
        fi
        _warn "Port ${port} is privileged. Running as root — proceeding."
    fi
}

# Root detection — safe, timeout-guarded, no hanging prompts  (v0.7)
_is_rooted() {
    # Fastest path: we are already root
    [[ "$(id -u 2>/dev/null)" == "0" ]] && return 0
    # su exists + timeout available → test with a 2-second ceiling
    if _has_binary su && _has_binary timeout; then
        timeout 2 su -c 'exit 0' &>/dev/null && return 0
    fi
    return 1
}

# Check whether a port is listening.
# Uses a word-boundary pattern so :80 doesn't match :8080.
_port_in_use() {
    local port="$1"
    if _has_binary ss; then
        ss -tlnp 2>/dev/null | grep -qE ":${port}(\s|$)" && return 0
    elif _has_binary netstat; then
        netstat -tlnp 2>/dev/null | grep -qE ":${port}(\s|$)" && return 0
    else
        (echo >/dev/tcp/127.0.0.1/"${port}") &>/dev/null && return 0
    fi
    return 1
}

# Best-effort: print who owns a port
_port_owner() {
    local port="$1"
    if _has_binary ss; then
        ss -tlnp 2>/dev/null | grep -E ":${port}(\s|$)" | awk '{print $NF}' | head -1
    elif _has_binary lsof; then
        lsof -i :"${port}" -sTCP:LISTEN -t 2>/dev/null | head -1
    else
        echo "(unknown — install iproute2 or lsof for details)"
    fi
}

# ---------------------------------------------------------------------------
# RUNTIME DATABASE HELPERS (plain-text TSV)
# ---------------------------------------------------------------------------
# Schema: PORT<TAB>PID<TAB>BACKEND<TAB>DIRECTORY<TAB>LOGFILE<TAB>EPOCH<TAB>FILENAME
# Fields:   1      2    3        4          5         6       7

_db_add() {
    local port="$1" pid="$2" backend="$3" dir="$4" logfile="$5" serve_file="${6:-}"
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
        "$port" "$pid" "$backend" "$dir" "$logfile" "$(date +%s)" "$serve_file" \
        >> "${WERSER_DB}"
}

_db_remove() {
    local port="$1" tmp
    tmp=$(mktemp "${WERSER_CONFIG_DIR}/db.XXXXXX")
    grep -v "^${port}"$'\t' "${WERSER_DB}" > "$tmp" 2>/dev/null || true
    mv "$tmp" "${WERSER_DB}" || { rm -f "$tmp"; return 1; }
}

# _db_get <port> <field_number>
_db_get() {
    grep "^${1}"$'\t' "${WERSER_DB}" 2>/dev/null | head -1 | cut -f"${2}"
}

_db_list_ports() {
    awk -F'\t' 'NF>0{print $1}' "${WERSER_DB}" 2>/dev/null
}

_db_has() {
    grep -q "^${1}"$'\t' "${WERSER_DB}" 2>/dev/null
}

# Remove entries whose PID is no longer running; warn and log each crash.
_db_prune() {
    [[ ! -f "${WERSER_DB}" ]] && return 0
    local tmp
    tmp=$(mktemp "${WERSER_CONFIG_DIR}/db.XXXXXX")
    # Declare these local so the loop does not clobber caller variables
    # (bash dynamic scoping would otherwise let "read" overwrite them).
    local port pid backend dir logfile epoch serve_file
    while IFS=$'\t' read -r port pid backend dir logfile epoch serve_file; do
        [[ -z "$port" ]] && continue
        if kill -0 "$pid" 2>/dev/null; then
            printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
                "$port" "$pid" "$backend" "$dir" "$logfile" "$epoch" "$serve_file" >> "$tmp"
        else
            _warn "Server on port ${port} (PID ${pid}, ${backend}) stopped unexpectedly."
            # Append to persistent crash log
            printf "[%s] port=%s pid=%s backend=%s dir=%s\n" \
                "$(date '+%Y-%m-%d %H:%M:%S')" \
                "$port" "$pid" "$backend" "$dir" \
                >> "${WERSER_CRASH_LOG}" 2>/dev/null || true
        fi
    done < "${WERSER_DB}" 2>/dev/null || true
    mv "$tmp" "${WERSER_DB}" || rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# DB LOCK — serialise concurrent webstart/webstop calls
# ---------------------------------------------------------------------------

# Acquire the DB lock.  Waits up to 5 s, auto-clears stale locks.
_db_lock() {
    local i=0
    while ! mkdir "${WERSER_LOCK}" 2>/dev/null; do
        (( i++ ))
        if (( i >= 50 )); then
            local lock_pid
            lock_pid=$(cat "${WERSER_LOCK}/pid" 2>/dev/null || true)
            if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
                _warn "Removing stale lock (owner PID ${lock_pid} is gone)."
                rm -rf "${WERSER_LOCK}"
                i=0
                continue
            fi
            _err "Could not acquire DB lock after 5 s."
            _err "If this persists, remove: ${WERSER_LOCK}"
            return 1
        fi
        sleep 0.1
    done
    echo $$ > "${WERSER_LOCK}/pid"
}

# Release the DB lock.
_db_unlock() {
    rm -rf "${WERSER_LOCK}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# webhelp
# ---------------------------------------------------------------------------

webhelp() {
    local D="${C_DIM}"
    local R="${C_RESET}"
    local G="${C_BGREEN}"
    local Y="${C_BYELLOW}"
    local B="${C_BBLUE}"
    local C="${C_BCYAN}"
    local W="${C_BWHITE}"
    local E="${C_BRED}"
    local sep="${C_DIM}  ·  ${C_RESET}"

    printf "\n"
    printf "${B}╔══════════════════════════════════════════════════════════╗${R}\n"
    printf "${B}║${R}        ${W}webser${R} — Local Web Server Manager ${D}v%-12s${R}${B}║${R}\n" "${WERSER_VERSION}"
    printf "${B}╚══════════════════════════════════════════════════════════╝${R}\n"
    printf "\n"

    # ── STARTING SERVERS ──────────────────────────────────────────────────────
    printf "${C}  STARTING SERVERS${R}\n"
    printf "${D}  ──────────────────────────────────────────────────────────${R}\n"
    printf "\n"
    printf "  ${G}webstart${R} ${Y}<port>${R}\n"
    printf "  ${D}  Serve the current directory on <port>.${R}\n"
    printf "\n"
    printf "  ${G}webstart${R} ${Y}<port> <directory>${R}\n"
    printf "  ${D}  Serve a specific directory. Absolute or relative paths both work.${R}\n"
    printf "  ${D}  The directory is served at the root URL (/).${R}\n"
    printf "\n"
    printf "  ${G}webstart${R} ${Y}<port> <file>${R}\n"
    printf "  ${D}  Serve a single file. The output shows the direct URL to open it.${R}\n"
    printf "  ${D}  The parent directory is served; the URL points straight to the file.${R}\n"
    printf "\n"
    printf "  ${G}webstart${R} ${Y}--backend <name> <port> [<path>]${R}\n"
    printf "  ${D}  Force a specific backend: ${R}${Y}python${D} | ${Y}flask${D} | ${Y}busybox${D} | ${Y}php${D} | ${Y}node${R}\n"
    printf "\n"
    printf "  ${D}  Examples:${R}\n"
    printf "  ${D}    webstart 8080                       # serve current directory${R}\n"
    printf "  ${D}    webstart 8080 ~/mysite              # serve specific directory${R}\n"
    printf "  ${D}    webstart 8080 /absolute/path/site   # absolute path${R}\n"
    printf "  ${D}    webstart 9000 index.html            # direct URL to file shown${R}\n"
    printf "  ${D}    webstart --backend flask 5000       # force Flask backend${R}\n"
    printf "\n"

    # ── STARTING MULTIPLE SERVERS ──────────────────────────────────────────
    printf "${C}  STARTING MULTIPLE SERVERS AT ONCE${R}\n"
    printf "${D}  ──────────────────────────────────────────────────────────${R}\n"
    printf "\n"
    printf "  ${G}webmulti${R} ${Y}<port1> <port2> [... portN]${R}\n"
    printf "  ${D}  Start multiple servers on different ports, all serving the current directory.${R}\n"
    printf "\n"
    printf "  ${G}webmulti${R} ${Y}<port1> <port2> [... portN] <directory>${R}\n"
    printf "  ${D}  Start multiple servers all serving the same directory or file.${R}\n"
    printf "\n"
    printf "  ${G}webmulti${R} ${Y}--backend <name> <port1> <port2> [... portN] [<path>]${R}\n"
    printf "  ${D}  Same, but force a specific backend for all servers.${R}\n"
    printf "\n"
    printf "  ${D}  The output shows a Local URL and LAN URL for every started port.${R}\n"
    printf "  ${D}  A summary at the end lists which ports succeeded and which failed.${R}\n"
    printf "\n"
    printf "  ${D}  Examples:${R}\n"
    printf "  ${D}    webmulti 8080 8081 8082             # three servers, current dir${R}\n"
    printf "  ${D}    webmulti 8080 9000 ~/site           # two servers, same directory${R}\n"
    printf "  ${D}    webmulti --backend flask 5000 5001  # two Flask servers${R}\n"
    printf "\n"

    # ── STOPPING SERVERS ──────────────────────────────────────────────────────
    printf "${C}  STOPPING SERVERS${R}\n"
    printf "${D}  ──────────────────────────────────────────────────────────${R}\n"
    printf "\n"
    printf "  ${G}webstop${R}\n"
    printf "  ${D}  Stop ${R}${W}all${R}${D} running servers.${R}\n"
    printf "\n"
    printf "  ${G}webstop${R} ${Y}<port>${R}\n"
    printf "  ${D}  Stop only the server on <port>.${R}\n"
    printf "\n"

    # ── VIEWING & MONITORING ──────────────────────────────────────────────────
    printf "${C}  VIEWING & MONITORING${R}\n"
    printf "${D}  ──────────────────────────────────────────────────────────${R}\n"
    printf "\n"
    printf "  ${G}weblist${R}\n"
    printf "  ${D}  List all running servers (port, backend, PID, uptime, status).${R}\n"
    printf "\n"
    printf "  ${G}webstatus${R} ${Y}<port>${R}\n"
    printf "  ${D}  Detailed view of one server: URLs, log path, running time.${R}\n"
    printf "\n"
    printf "  ${G}webshow${R} ${Y}<port>${R}\n"
    printf "  ${D}  Stream live server logs. Interactive prompt at the bottom:${R}\n"
    printf "  ${D}    ${R}${Y}webhide${D}    — exit log view (server keeps running)${R}\n"
    printf "  ${D}    ${R}${Y}webstop${D}    — stop this server and exit${R}\n"
    printf "  ${D}    ${R}${Y}weblist${D}    — print server table inline${R}\n"
    printf "  ${D}    ${R}${Y}webstatus${D}  — print status inline${R}\n"
    printf "  ${D}    ${R}${Y}q / quit${D}   — same as webhide${R}\n"
    printf "\n"
    printf "  ${G}webhide${R}\n"
    printf "  ${D}  Exit webshow. Only useful inside the webshow prompt.${R}\n"
    printf "\n"

    # ── LOGS ──────────────────────────────────────────────────────────────────
    printf "${C}  LOGS${R}\n"
    printf "${D}  ──────────────────────────────────────────────────────────${R}\n"
    printf "\n"
    printf "  ${G}weblogs${R}\n"
    printf "  ${D}  List all log files with size and date.${R}\n"
    printf "\n"
    printf "  ${G}weblogs${R} ${Y}<port>${R}\n"
    printf "  ${D}  Print the full log for that server.${R}\n"
    printf "\n"
    printf "  ${G}webclearlogs${R}\n"
    printf "  ${D}  Delete logs for stopped servers. Active logs are never touched.${R}\n"
    printf "\n"

    # ── MAINTENANCE ───────────────────────────────────────────────────────────
    printf "${C}  MAINTENANCE${R}\n"
    printf "${D}  ──────────────────────────────────────────────────────────${R}\n"
    printf "\n"
    printf "  ${G}webclear${R}\n"
    printf "  ${D}  Remove stale cache files, dead DB entries, and temp files.${R}\n"
    printf "  ${D}  ${R}${W}Never${R}${D} touches your own files.${R}\n"
    printf "\n"
    printf "  ${G}webver${R}\n"
    printf "  ${D}  Show version, config paths, and installed backend status.${R}\n"
    printf "\n"
    printf "  ${G}webhelp${R}\n"
    printf "  ${D}  Show this screen.${R}\n"
    printf "\n"

    # ── BACKENDS ──────────────────────────────────────────────────────────────
    printf "${C}  BACKENDS${R}  ${D}(auto-selected by priority — first available wins)${R}\n"
    printf "${D}  ──────────────────────────────────────────────────────────${R}\n"
    printf "\n"
    printf "  ${W}1${R}  Python http.server  ${D}→  pkg install python${R}\n"
    printf "  ${W}2${R}  Flask               ${D}→  pip install flask${R}\n"
    printf "  ${W}3${R}  BusyBox httpd       ${D}→  pkg install busybox${R}\n"
    printf "  ${W}4${R}  PHP built-in        ${D}→  pkg install php${R}\n"
    printf "  ${W}5${R}  Node http-server    ${D}→  pkg install nodejs  then  npm i -g http-server${R}\n"
    printf "\n"
    printf "  ${D}Run ${R}${G}webver${D} to see which backends are installed on this device.${R}\n"
    printf "\n"

    # ── COMMON ERRORS ─────────────────────────────────────────────────────────
    printf "${C}  COMMON ERRORS${R}\n"
    printf "${D}  ──────────────────────────────────────────────────────────${R}\n"
    printf "\n"
    printf "  ${E}Port already in use${R}    →  ${Y}webstop <port>${R}${D}  or pick another port${R}\n"
    printf "  ${E}No backend found${R}        →  ${Y}pkg install python${R}${D}  (recommended)${R}\n"
    printf "  ${E}Port < 1024${R}             →  ${D}Android blocks these without root; use ≥ 1024${R}\n"
    printf "  ${E}Server died immediately${R} →  ${Y}weblogs <port>${R}${D}  to see what went wrong${R}\n"
    printf "  ${E}Path does not exist${R}     →  ${D}check spelling; use absolute paths to avoid ambiguity${R}\n"
    printf "  ${E}Path not readable${R}       →  ${Y}ls -la <path>${R}${D}  to inspect permissions${R}\n"
    printf "\n"

    # ── TIPS ──────────────────────────────────────────────────────────────────
    printf "${C}  TIPS${R}\n"
    printf "${D}  ──────────────────────────────────────────────────────────${R}\n"
    printf "\n"
    printf "  ${D}•  Multiple servers can run on different ports at the same time.${R}\n"
    printf "  ${D}•  ${R}webstart 8080${D}  in any directory serves that directory.${R}\n"
    printf "  ${D}•  Use ${R}webmulti 8080 8081 8082${D}  to start several ports with one command.${R}\n"
    printf "  ${D}•  Paths may be relative or absolute; tilde (~) is expanded automatically.${R}\n"
    printf "  ${D}•  When a file is specified, the URL points directly to it — no browsing needed.${R}\n"
    printf "  ${D}•  Logs live in  ${R}~/.local/share/webserver/logs/${D}.${R}\n"
    printf "  ${D}•  State lives in  ${R}~/.config/webserver/${D}.${R}\n"
    printf "  ${D}•  Run ${R}webclear${D} occasionally to remove leftover temp files.${R}\n"
    printf "\n"
}

# ---------------------------------------------------------------------------
# NETWORK HELPERS
# ---------------------------------------------------------------------------

# Return the best Python binary (python3 preferred)
_python_bin() {
    if _has_binary python3; then echo "python3"
    elif _has_binary python; then echo "python"
    else echo ""; fi
}

# Return the device's LAN IP (best-effort, falls back to 127.0.0.1)
_local_ip() {
    local ip=""
    if _has_binary ip; then
        ip=$(ip route get 1.1.1.1 2>/dev/null \
            | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
    fi
    if [[ -z "$ip" ]] && _has_binary hostname; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    if [[ -z "$ip" ]] && _has_binary ifconfig; then
        ip=$(ifconfig 2>/dev/null \
            | awk '/inet / && !/127\.0\.0\.1/{print $2; exit}' \
            | sed 's/addr://')
    fi
    echo "${ip:-127.0.0.1}"
}

# ---------------------------------------------------------------------------
# PATH RESOLUTION
# ---------------------------------------------------------------------------

# Populate RESOLVED_DIR and RESOLVED_FILE from a user-supplied target.
# Target may be empty (→ pwd), a directory, or a file.
# Uses bash dynamic scoping — caller must declare these as local first.
_resolve_target() {
    local target="$1"
    RESOLVED_DIR=""
    RESOLVED_FILE=""

    if [[ -z "$target" ]]; then
        RESOLVED_DIR="$(pwd)"
        return 0
    fi

    # Expand leading tilde
    target="${target/#\~/$HOME}"

    # Track whether input was relative (for error hints)
    local was_relative=0
    [[ "$target" != /* ]] && was_relative=1

    # Make absolute — strip any trailing slash first to keep dirname/basename sane
    target="${target%/}"
    [[ "$target" != /* ]] && target="$(pwd)/${target}"

    # Canonicalise (remove . and .. components) — prefer realpath, fall back to
    # a pure-bash loop so it works even when coreutils are not installed.
    if _has_binary realpath; then
        local resolved
        resolved="$(realpath "$target" 2>/dev/null)"
        # realpath returns non-zero AND prints nothing when path does not exist;
        # in that case keep the un-resolved absolute path so the error below is accurate.
        [[ -n "$resolved" ]] && target="$resolved"
    fi

    if [[ ! -e "$target" ]]; then
        _err "Path does not exist: ${target}"
        if (( was_relative )); then
            printf "  ${C_DIM}Searched in: %s${C_RESET}\n" "$(pwd)"
            printf "  ${C_DIM}Tip: use an absolute path to avoid ambiguity, e.g.${C_RESET}\n"
            printf "    ${C_BYELLOW}webstart <port> %s/%s${C_RESET}\n" "$(pwd)" "$(basename "$target")"
        else
            printf "  ${C_DIM}Double-check the path is correct.${C_RESET}\n"
            printf "  ${C_DIM}Run ${C_BYELLOW}ls -la \"%s\"${C_DIM} to inspect the parent directory.${C_RESET}\n" "$(dirname "$target")"
        fi
        return 1
    fi

    if [[ -d "$target" ]]; then
        if [[ ! -r "$target" ]]; then
            _err "Directory is not readable: ${target}"
            printf "  ${C_DIM}Check permissions with: ${C_BYELLOW}ls -la \"%s\"${C_RESET}\n" "$(dirname "$target")"
            return 1
        fi
        RESOLVED_DIR="$target"
    elif [[ -f "$target" ]]; then
        if [[ ! -r "$target" ]]; then
            _err "File is not readable: ${target}"
            printf "  ${C_DIM}Check permissions with: ${C_BYELLOW}ls -la \"%s\"${C_RESET}\n" "$(dirname "$target")"
            return 1
        fi
        RESOLVED_DIR="$(dirname "$target")"
        RESOLVED_FILE="$(basename "$target")"
    else
        _err "Path is neither a regular file nor a directory: ${target}"
        printf "  ${C_DIM}Symbolic links, device nodes, and pipes are not supported.${C_RESET}\n"
        return 1
    fi

    # Refuse obviously dangerous system directories
    case "$RESOLVED_DIR" in
        /|/etc|/bin|/sbin|/usr|/boot|/proc|/sys|/dev)
            _err "Refusing to serve a sensitive system directory: ${RESOLVED_DIR}"
            printf "  ${C_DIM}Serve a sub-directory instead.${C_RESET}\n"
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# BACKEND: Python http.server  (Priority 1)
# ---------------------------------------------------------------------------

_backend_python() {
    local port="$1" serve_dir="$2" logfile="$3"
    local pybin
    pybin=$(_python_bin)
    if [[ -z "$pybin" ]]; then _missing_dep "python3"; return 1; fi

    # --directory flag available since Python 3.7 — standard on modern Termux
    # --bind 0.0.0.0 required: Python 3.6+ defaults to 127.0.0.1, breaking LAN access
    nohup "$pybin" -m http.server "$port" \
        --bind 0.0.0.0 --directory "$serve_dir" >> "$logfile" 2>&1 &
    echo $!
}

# ---------------------------------------------------------------------------
# BACKEND: Flask  (Priority 2)
# ---------------------------------------------------------------------------

_backend_flask() {
    local port="$1" serve_dir="$2" logfile="$3" serve_file="${4:-}"
    local pybin
    pybin=$(_python_bin)
    if [[ -z "$pybin" ]]; then _missing_dep "python3"; return 1; fi
    if ! _has_python_module "flask"; then
        _err "Flask is not installed."
        printf "  ${C_DIM}Install: ${C_BYELLOW}pip install flask${C_RESET}\n"
        return 1
    fi

    # Write a minimal Flask static-file server to the config dir so it
    # persists (webclear cleans it up) and is readable after nohup forks.
    local script="${WERSER_CONFIG_DIR}/flask_${port}.py"
    cat > "$script" << 'PYEOF'
import sys, os, mimetypes
from flask import Flask, Response, abort, redirect

serve_dir  = os.path.realpath(sys.argv[1])
port_num   = int(sys.argv[2])
# serve_file: basename of a specific file to serve at root (may be empty)
serve_file = sys.argv[3] if len(sys.argv) > 3 else ''
app        = Flask(__name__)

@app.route('/', defaults={'path': ''})
@app.route('/<path:path>')
def serve(path):
    # When a specific file was requested and the client hits root, redirect
    # directly to that file so the URL opens it immediately.
    if not path and serve_file:
        return redirect('/' + serve_file, code=302)
    target = os.path.realpath(os.path.join(serve_dir, path))
    # Prevent path-traversal attacks
    if not (target == serve_dir or target.startswith(serve_dir + os.sep)):
        abort(403)
    if os.path.isdir(target):
        idx = os.path.join(target, 'index.html')
        if os.path.isfile(idx):
            target = idx
        else:
            try:
                items  = sorted(os.listdir(target))
                prefix = '/' + path.strip('/') + '/' if path.strip('/') else '/'
                rows   = ''.join(
                    '<li><a href="{p}{n}">{n}</a></li>'.format(p=prefix, n=i)
                    for i in items)
                return Response(
                    '<html><head><title>{p}</title></head>'
                    '<body><h2>{p}</h2><ul>{r}</ul></body></html>'.format(
                        p=prefix, r=rows),
                    mimetype='text/html')
            except PermissionError:
                abort(403)
    if not os.path.isfile(target):
        abort(404)
    mime, _ = mimetypes.guess_type(target)
    with open(target, 'rb') as fh:
        return Response(fh.read(), mimetype=mime or 'application/octet-stream')

app.run(host='0.0.0.0', port=port_num, debug=False, use_reloader=False)
PYEOF

    nohup "$pybin" "$script" "$serve_dir" "$port" "$serve_file" >> "$logfile" 2>&1 &
    echo $!
}

# ---------------------------------------------------------------------------
# BACKEND: BusyBox httpd  (Priority 3)
# ---------------------------------------------------------------------------

_backend_busybox() {
    local port="$1" serve_dir="$2" logfile="$3"
    if ! _has_binary busybox; then _missing_dep "busybox"; return 1; fi
    if ! busybox --list 2>/dev/null | grep -q "^httpd$"; then
        _err "This BusyBox build does not include httpd."
        printf "  ${C_DIM}Reinstall: ${C_BYELLOW}pkg install busybox${C_RESET}\n"
        return 1
    fi
    # -f = foreground  -p = port  -h = document root
    nohup busybox httpd -f -p "$port" -h "$serve_dir" >> "$logfile" 2>&1 &
    echo $!
}

# ---------------------------------------------------------------------------
# BACKEND: PHP built-in server  (Priority 4)
# ---------------------------------------------------------------------------

_backend_php() {
    local port="$1" serve_dir="$2" logfile="$3"
    if ! _has_binary php; then _missing_dep "php"; return 1; fi
    # -S addr:port  -t document_root
    nohup php -S "0.0.0.0:${port}" -t "$serve_dir" >> "$logfile" 2>&1 &
    echo $!
}

# ---------------------------------------------------------------------------
# BACKEND: Node http-server  (Priority 5)
# ---------------------------------------------------------------------------

_has_node_httpserver() {
    _has_binary http-server && return 0
    # Accept npx only if http-server is already locally cached (no download)
    _has_binary npx && npx --no-install http-server --version &>/dev/null && return 0
    return 1
}

_backend_node() {
    local port="$1" serve_dir="$2" logfile="$3"
    if ! _has_node_httpserver; then
        _err "Node http-server is not available."
        printf "  ${C_DIM}Install: ${C_BYELLOW}npm install -g http-server${C_RESET}\n"
        printf "  ${C_DIM}(after:  ${C_BYELLOW}pkg install nodejs${C_RESET}${C_DIM})${C_RESET}\n"
        return 1
    fi
    if _has_binary http-server; then
        nohup http-server "$serve_dir" -p "$port" --cors >> "$logfile" 2>&1 &
    else
        nohup npx --no-install http-server "$serve_dir" -p "$port" --cors \
            >> "$logfile" 2>&1 &
    fi
    echo $!
}

# ---------------------------------------------------------------------------
# BACKEND SELECTOR
# ---------------------------------------------------------------------------

# _select_backend [forced_name]
# Sets SELECTED_BACKEND via dynamic scoping (caller declares it local).
# On forced-backend failure, falls back to auto-select and warns.
_select_backend() {
    local forced="${1:-}"
    SELECTED_BACKEND=""

    # ---- Forced selection ----
    if [[ -n "$forced" ]]; then
        case "$forced" in
            python|python3)
                if [[ -n "$(_python_bin)" ]]; then
                    SELECTED_BACKEND="python"; return 0
                fi
                _warn "Python not found. Trying other backends..."
                ;;
            flask)
                if [[ -n "$(_python_bin)" ]] && _has_python_module "flask"; then
                    SELECTED_BACKEND="flask"; return 0
                fi
                _warn "Flask not available. Trying other backends..."
                ;;
            busybox)
                if _has_binary busybox && busybox --list 2>/dev/null | grep -q "^httpd$"; then
                    SELECTED_BACKEND="busybox"; return 0
                fi
                _warn "BusyBox httpd not available. Trying other backends..."
                ;;
            php)
                if _has_binary php; then
                    SELECTED_BACKEND="php"; return 0
                fi
                _warn "PHP not found. Trying other backends..."
                ;;
            node)
                if _has_node_httpserver; then
                    SELECTED_BACKEND="node"; return 0
                fi
                _warn "Node http-server not available. Trying other backends..."
                ;;
            *)
                _err "Unknown backend: '${forced}'. Valid: python, flask, busybox, php, node"
                return 1
                ;;
        esac
        # Forced backend unavailable — fall through to auto-select
        _info "Falling back to automatic backend selection..."
    fi

    # ---- Auto-selection — priority order ----
    # Python http.server (#1) is always preferred over Flask (#2) when a
    # Python binary is present — which is also required for Flask to work.
    # The flask line below is therefore only reachable on a system where
    # no Python binary exists in PATH but the flask module is somehow
    # importable (essentially impossible in practice; kept for completeness).
    if [[ -n "$(_python_bin)" ]];                                             then SELECTED_BACKEND="python";  return 0; fi
    if _has_python_module "flask";                                             then SELECTED_BACKEND="flask";   return 0; fi
    if _has_binary busybox && busybox --list 2>/dev/null | grep -q "^httpd$"; then SELECTED_BACKEND="busybox"; return 0; fi
    if _has_binary php;                                                        then SELECTED_BACKEND="php";     return 0; fi
    if _has_node_httpserver;                                                   then SELECTED_BACKEND="node";    return 0; fi

    _err "No supported backend found on this device."
    printf "\n  ${C_DIM}Install one of:${C_RESET}\n"
    printf "    ${C_BYELLOW}pkg install python${C_RESET}                    ${C_DIM}(recommended)${C_RESET}\n"
    printf "    ${C_BYELLOW}pkg install busybox${C_RESET}\n"
    printf "    ${C_BYELLOW}pkg install php${C_RESET}\n"
    printf "    ${C_BYELLOW}pkg install nodejs${C_RESET} ${C_DIM}then:${C_RESET} ${C_BYELLOW}npm install -g http-server${C_RESET}\n"
    return 1
}

# ---------------------------------------------------------------------------
# SERVER LAUNCHER — resolve → select → lock → start → verify → register
# ---------------------------------------------------------------------------

_launch_server() {
    local port="$1" target="${2:-}" forced_backend="${3:-}" _quiet="${4:-0}"

    # --- Port validation (fast, no I/O) ---
    _validate_port "$port"         || return 1
    _check_privileged_port "$port" || return 1

    # --- Port-in-use check (before lock — cheap early exit) ---
    if _port_in_use "$port"; then
        _err "Port ${port} is already in use."
        local owner
        owner=$(_port_owner "$port")
        [[ -n "$owner" ]] && printf "  ${C_DIM}Owned by: %s${C_RESET}\n" "$owner"
        printf "  ${C_DIM}To free it: ${C_BYELLOW}webstop %s${C_RESET}\n" "$port"
        local suggest=$(( port + 1 ))
        while _port_in_use "$suggest" && (( suggest < port + 20 )); do
            (( suggest++ ))
        done
        _port_in_use "$suggest" || \
            printf "  ${C_DIM}Or try port: ${C_BGREEN}%s${C_RESET}\n" "$suggest"
        return 1
    fi

    # --- Path resolution & backend selection (before lock — no DB access) ---
    local RESOLVED_DIR RESOLVED_FILE
    _resolve_target "$target" || return 1

    local SELECTED_BACKEND
    _select_backend "$forced_backend" || return 1

    # --- Acquire DB lock — serialise concurrent webstart calls ---
    _db_lock || return 1

    # Re-check inside the lock: another call may have claimed this port
    if _db_has "$port"; then
        _db_unlock
        _err "webser is already managing a server on port ${port}."
        printf "  ${C_DIM}Run: ${C_BYELLOW}webstop %s${C_RESET} first.\n" "$port"
        return 1
    fi

    # --- Prepare log file (rotate old one to preserve history) ---
    local logfile="${WERSER_LOG_DIR}/webser_${port}.log"
    if [[ -f "$logfile" ]]; then
        mv "$logfile" "${logfile%.log}_$(date +%Y%m%d_%H%M%S).log"
    fi
    touch "$logfile"

    # --- Launch backend ---
    _info "Starting ${SELECTED_BACKEND} server on port ${port}..."
    if [[ -n "$RESOLVED_FILE" ]]; then
        _info "Serving file:      ${RESOLVED_DIR}/${RESOLVED_FILE}"
    else
        _info "Serving directory: ${RESOLVED_DIR}"
    fi

    local pid=""
    case "$SELECTED_BACKEND" in
        python)  pid=$(_backend_python  "$port" "$RESOLVED_DIR" "$logfile" "${RESOLVED_FILE:-}") ;;
        flask)   pid=$(_backend_flask   "$port" "$RESOLVED_DIR" "$logfile" "${RESOLVED_FILE:-}") ;;
        busybox) pid=$(_backend_busybox "$port" "$RESOLVED_DIR" "$logfile") ;;
        php)     pid=$(_backend_php     "$port" "$RESOLVED_DIR" "$logfile") ;;
        node)    pid=$(_backend_node    "$port" "$RESOLVED_DIR" "$logfile") ;;
        *)
            _db_unlock
            _err "Internal error: unknown backend '${SELECTED_BACKEND}'."
            return 1
            ;;
    esac

    if [[ -z "$pid" ]]; then
        _db_unlock
        _err "Failed to start server (no PID returned)."
        return 1
    fi

    # --- Startup verification — retry up to ~1.5 s ---
    local alive=0 attempt
    for attempt in 1 2 3 4 5; do
        if kill -0 "$pid" 2>/dev/null; then
            alive=1; break
        fi
        sleep 0.3
    done

    if [[ $alive -eq 0 ]]; then
        _db_unlock
        _err "Server process (PID ${pid}) died immediately. Check logs:"
        printf "  ${C_DIM}%s${C_RESET}\n" "$logfile"
        if [[ -s "$logfile" ]]; then
            printf "  ${C_DIM}Last log lines:${C_RESET}\n"
            tail -5 "$logfile" | sed 's/^/    /'
        fi
        return 1
    fi

    # --- Register in DB (still inside lock) ---
    _db_add "$port" "$pid" "$SELECTED_BACKEND" "$RESOLVED_DIR" "$logfile" "${RESOLVED_FILE:-}"
    _db_unlock

    # --- Success output ---
    local lan_ip url_suffix=""
    lan_ip=$(_local_ip)
    # When a specific file was requested, the direct URL includes the filename
    # so the user can open it immediately without navigating a directory listing.
    [[ -n "$RESOLVED_FILE" ]] && url_suffix="/${RESOLVED_FILE}"

    printf "\n"
    _ok "Server started successfully!"
    printf "\n"
    _detail "Port"      "${port}"
    _detail "Backend"   "${SELECTED_BACKEND}"
    _detail "PID"       "${pid}"
    if [[ -n "$RESOLVED_FILE" ]]; then
        _detail "Serving"   "${RESOLVED_DIR}/${RESOLVED_FILE}"
    else
        _detail "Serving"   "${RESOLVED_DIR}"
    fi
    _detail "Local URL" "${C_BGREEN}http://127.0.0.1:${port}${url_suffix}${C_RESET}"
    _detail "LAN URL"   "${C_BGREEN}http://${lan_ip}:${port}${url_suffix}${C_RESET}"
    if [[ -n "$url_suffix" ]]; then
        _detail "Direct file" "${C_DIM}→ the URL above opens the file directly${C_RESET}"
    fi
    _detail "Logs"      "${logfile}"
    printf "\n"
    if [[ "$_quiet" != "1" ]]; then
        _info "Use ${C_BWHITE}webshow ${port}${C_RESET} to stream live logs."
        _info "Use ${C_BWHITE}webstop ${port}${C_RESET} to stop this server."
        printf "\n"
    fi
}

# ---------------------------------------------------------------------------
# webstart
# ---------------------------------------------------------------------------

webstart() {
    _init_dirs || return 1

    local forced_backend="" args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --backend)
                if [[ -z "${2:-}" ]]; then
                    _err "--backend requires a name (python|flask|busybox|php|node)."
                    return 1
                fi
                forced_backend="$2"; shift 2
                ;;
            -*) _err "Unknown option: '$1'. Run: ${C_BWHITE}webhelp${C_RESET}"; return 1 ;;
            *)  args+=("$1"); shift ;;
        esac
    done

    local port="${args[0]:-}" target="${args[1]:-}"

    if [[ -z "$port" ]]; then
        _err "Usage: webstart [--backend <name>] <port> [<path>]"
        return 1
    fi

    _launch_server "$port" "$target" "$forced_backend"
}

# ---------------------------------------------------------------------------
# webmulti — start multiple servers at once  (v1.1)
# ---------------------------------------------------------------------------
#
# Usage:
#   webmulti <port1> <port2> [... portN]
#   webmulti <port1> <port2> [... portN] <directory>
#   webmulti --backend <name> <port1> <port2> [... portN] [<path>]
#
# All numeric positional arguments are treated as ports.
# The first non-numeric positional argument (if any) is treated as the path
# (directory or file) to serve — identical to webstart's second argument.
#
# Each port is started sequentially so that DB locking and startup checks
# remain reliable.  The overall success/failure summary is printed at the end.
# ---------------------------------------------------------------------------

webmulti() {
    _init_dirs || return 1

    local forced_backend="" args=()

    # --- Parse options ---
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --backend)
                if [[ -z "${2:-}" ]]; then
                    _err "--backend requires a name (python|flask|busybox|php|node)."
                    return 1
                fi
                forced_backend="$2"; shift 2
                ;;
            -*) _err "Unknown option: '$1'. Run: ${C_BWHITE}webhelp${C_RESET}"; return 1 ;;
            *)  args+=("$1"); shift ;;
        esac
    done

    if [[ ${#args[@]} -eq 0 ]]; then
        _err "Usage: webmulti [--backend <name>] <port1> <port2> [... portN] [<path>]"
        return 1
    fi

    # --- Split args: numeric → ports; first non-numeric → path ---
    local ports=() target=""
    local a
    for a in "${args[@]}"; do
        if [[ "$a" =~ ^[0-9]+$ ]]; then
            ports+=("$a")
        else
            if [[ -z "$target" ]]; then
                target="$a"
            else
                _err "Unexpected argument: '${a}'. Only one path may be specified."
                return 1
            fi
        fi
    done

    if [[ ${#ports[@]} -eq 0 ]]; then
        _err "No ports specified. Provide at least one numeric port."
        _err "Usage: webmulti [--backend <name>] <port1> <port2> [... portN] [<path>]"
        return 1
    fi

    if [[ ${#ports[@]} -eq 1 && -z "$target" ]]; then
        _warn "Only one port given — use ${C_BWHITE}webstart ${ports[0]}${C_RESET} for a single server."
    fi

    # --- Pre-validate path once so every port gets the same resolved target ---
    # Validate target early, before locking anything.
    if [[ -n "$target" ]]; then
        local RESOLVED_DIR RESOLVED_FILE
        _resolve_target "$target" || return 1
        # Re-use the resolved values for all ports (passed via shared vars below)
    fi

    # --- Header ---
    printf "\n"
    _info "Starting ${C_BWHITE}${#ports[@]}${C_RESET} server(s)${target:+ for: ${C_BCYAN}${target}${C_RESET}}..."
    printf "\n"

    # --- Launch each port ---
    local ok_ports=() fail_ports=()
    local p
    for p in "${ports[@]}"; do
        _launch_server "$p" "$target" "$forced_backend" "1"
        if [[ $? -eq 0 ]]; then
            ok_ports+=("$p")
        else
            fail_ports+=("$p")
        fi
        # Brief gap between launches to avoid simultaneous port-in-use races
        [[ ${#ports[@]} -gt 1 ]] && sleep 0.2
    done

    # --- Summary ---
    printf "\n"
    local lan_ip
    lan_ip=$(_local_ip)

    if [[ ${#ok_ports[@]} -gt 0 ]]; then
        _ok "${#ok_ports[@]} server(s) started:"
        local sp
        for sp in "${ok_ports[@]}"; do
            local sf
            sf=$(_db_get "$sp" 7)
            local suffix=""
            [[ -n "$sf" ]] && suffix="/${sf}"
            printf "    ${C_BGREEN}%-6s${C_RESET}  Local: ${C_BGREEN}http://127.0.0.1:${sp}${suffix}${C_RESET}  |  LAN: ${C_BGREEN}http://${lan_ip}:${sp}${suffix}${C_RESET}\n" "$sp"
        done
    fi

    if [[ ${#fail_ports[@]} -gt 0 ]]; then
        printf "\n"
        _err "${#fail_ports[@]} server(s) failed to start: ${fail_ports[*]}"
        printf "  ${C_DIM}Run ${C_BYELLOW}weblist${C_DIM} to see what is currently running.${C_RESET}\n"
    fi

    if [[ ${#ok_ports[@]} -gt 0 ]]; then
        printf "\n"
        _info "Use ${C_BWHITE}weblist${C_RESET} to see all running servers."
        _info "Use ${C_BWHITE}webstop${C_RESET} to stop all servers, or ${C_BWHITE}webstop <port>${C_RESET} for one."
    fi
    printf "\n"

    # Return non-zero if any port failed
    [[ ${#fail_ports[@]} -eq 0 ]]
}

# ---------------------------------------------------------------------------
# webstop
# ---------------------------------------------------------------------------

# Internal: kill a PID cleanly (SIGTERM → wait up to 3 s → SIGKILL)
_kill_pid() {
    local pid="$1"
    if ! kill -0 "$pid" 2>/dev/null; then
        _warn "Process ${pid} was already gone."
        return 0
    fi

    kill -TERM "$pid" 2>/dev/null

    local i=0
    while kill -0 "$pid" 2>/dev/null && (( i < 6 )); do
        sleep 0.5; (( i++ ))
    done

    if kill -0 "$pid" 2>/dev/null; then
        _warn "Process ${pid} did not exit cleanly; sending SIGKILL..."
        kill -KILL "$pid" 2>/dev/null || true
    fi

    # Also reap any child processes of pid (best-effort, non-fatal)
    if _has_binary pkill; then
        pkill -KILL -P "$pid" 2>/dev/null || true
    fi
}

webstop() {
    _init_dirs || return 1
    _db_prune   # warn about and remove any already-dead entries

    local port="${1:-}"

    # --- Stop a single server ---
    if [[ -n "$port" ]]; then
        _validate_port "$port" || return 1

        if ! _db_has "$port"; then
            _err "No webser-managed server found on port ${port}."
            _info "Run ${C_BWHITE}weblist${C_RESET} to see running servers."
            return 1
        fi

        local pid
        pid=$(_db_get "$port" 2)
        _info "Stopping server on port ${port} (PID ${pid})..."
        _kill_pid "$pid"
        if _db_lock; then
            _db_remove "$port"
            _db_unlock
        else
            _warn "Could not acquire lock; DB entry for port ${port} may remain. Remove manually if needed."
        fi
        _ok "Server on port ${port} stopped."
        return 0
    fi

    # --- Stop ALL servers ---
    local ports
    ports=$(_db_list_ports)

    if [[ -z "$ports" ]]; then
        _info "No webser-managed servers are currently running."
        return 0
    fi

    local count=0 pid p
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        pid=$(_db_get "$p" 2)
        _info "Stopping port ${p} (PID ${pid})..."
        _kill_pid "$pid"
        (( ++count ))
    done <<< "$ports"

    # Remove all DB entries in one locked operation (avoids per-server lock churn)
    if _db_lock; then
        while IFS= read -r p; do
            [[ -z "$p" ]] && continue
            _db_remove "$p"
        done <<< "$ports"
        _db_unlock
    else
        _warn "Could not acquire DB lock; stale entries may remain. Run: ${C_BWHITE}webclear${C_RESET}"
    fi

    _ok "Stopped ${count} server(s)."
}

# ---------------------------------------------------------------------------
# TIME HELPERS
# ---------------------------------------------------------------------------

# Convert an epoch timestamp to a human-readable local datetime string.
_format_epoch() {
    local epoch="$1"
    # GNU date -d first, BSD date -r as fallback
    date -d "@${epoch}" "+%Y-%m-%d %H:%M:%S" 2>/dev/null \
        || date -r "${epoch}"  "+%Y-%m-%d %H:%M:%S" 2>/dev/null \
        || echo "(unknown)"
}

# Convert seconds into a compact human-readable uptime string.
_format_uptime() {
    local secs="$1" d h m s
    (( d = secs / 86400 ))
    (( h = (secs % 86400) / 3600 ))
    (( m = (secs % 3600) / 60 ))
    (( s = secs % 60 ))

    if   (( d > 0 )); then printf "%dd %dh %dm"  "$d" "$h" "$m"
    elif (( h > 0 )); then printf "%dh %dm %ds"  "$h" "$m" "$s"
    elif (( m > 0 )); then printf "%dm %ds"       "$m" "$s"
    else                    printf "%ds"           "$s"
    fi
}

# Return current epoch (portable: no $EPOCHSECONDS dependency)
_now_epoch() { date +%s; }

# ---------------------------------------------------------------------------
# weblist
# ---------------------------------------------------------------------------

weblist() {
    _init_dirs || return 1
    _db_prune   # remove crashed entries and warn about them

    local ports
    ports=$(_db_list_ports)

    if [[ -z "$ports" ]]; then
        _info "No webser-managed servers are currently running."
        return 0
    fi

    local now
    now=$(_now_epoch)

    # Column widths
    local W_PORT=6 W_BACK=10 W_PID=8 W_UP=12 W_STATUS=10

    printf "\n"

    # Header row
    printf "${C_BBLUE}%-${W_PORT}s  %-${W_BACK}s  %-${W_PID}s  %-${W_UP}s  %-${W_STATUS}s  %s${C_RESET}\n" \
        "PORT" "BACKEND" "PID" "UPTIME" "STATUS" "DIRECTORY"

    # Divider
    local div=""
    local i; for (( i=0; i<78; i++ )); do div+="─"; done
    printf "${C_DIM}%s${C_RESET}\n" "$div"

    # One row per server
    local p
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue

        local pid backend dir epoch uptime status colour_s
        pid=$(_db_get "$p" 2)
        backend=$(_db_get "$p" 3)
        dir=$(_db_get "$p" 4)
        epoch=$(_db_get "$p" 6)

        # Running time
        if [[ -n "$epoch" && "$epoch" =~ ^[0-9]+$ ]]; then
            uptime=$(_format_uptime $(( now - epoch )))
        else
            uptime="?"
        fi

        # Status
        if kill -0 "$pid" 2>/dev/null; then
            status="running"
            colour_s="${C_BGREEN}"
        else
            status="stopped"
            colour_s="${C_BRED}"
        fi

        # Truncate long directory paths for list view
        local dir_display="$dir"
        if (( ${#dir} > 40 )); then
            dir_display="…${dir: -39}"
        fi
        # Replace $HOME with ~
        dir_display="${dir_display/#$HOME/~}"

        printf "%-${W_PORT}s  %-${W_BACK}s  %-${W_PID}s  %-${W_UP}s  ${colour_s}%-${W_STATUS}s${C_RESET}  %s\n" \
            "$p" "$backend" "$pid" "$uptime" "$status" "$dir_display"

    done <<< "$ports"

    printf "\n"
}

# ---------------------------------------------------------------------------
# HEALTH CHECK  (v0.7)
# ---------------------------------------------------------------------------

# Return 0 if the port is actively accepting TCP connections.
_server_responds() {
    local port="$1"
    (echo >/dev/tcp/127.0.0.1/"${port}") &>/dev/null && return 0
    return 1
}

# ---------------------------------------------------------------------------
# webstatus
# ---------------------------------------------------------------------------

webstatus() {
    _init_dirs || return 1

    local port="${1:-}"
    if [[ -z "$port" ]]; then
        _err "Usage: webstatus <port>"
        return 1
    fi
    _validate_port "$port" || return 1

    _db_prune

    if ! _db_has "$port"; then
        _err "No webser-managed server found on port ${port}."
        _info "Run ${C_BWHITE}weblist${C_RESET} to see all running servers."
        return 1
    fi

    local pid backend dir logfile epoch serve_file
    pid=$(_db_get        "$port" 2)
    backend=$(_db_get    "$port" 3)
    dir=$(_db_get        "$port" 4)
    logfile=$(_db_get    "$port" 5)
    epoch=$(_db_get      "$port" 6)
    serve_file=$(_db_get "$port" 7)

    local now started uptime lan_ip proc_status respond_status url_suffix=""
    now=$(_now_epoch)

    if [[ -n "$epoch" && "$epoch" =~ ^[0-9]+$ ]]; then
        started=$(_format_epoch "$epoch")
        uptime=$(_format_uptime $(( now - epoch )))
    else
        started="unknown"
        uptime="unknown"
    fi

    lan_ip=$(_local_ip)
    [[ -n "$serve_file" ]] && url_suffix="/${serve_file}"

    # Process alive check
    if kill -0 "$pid" 2>/dev/null; then
        proc_status="${C_BGREEN}● running${C_RESET}"
    else
        proc_status="${C_BRED}✗ stopped${C_RESET}"
    fi

    # Network health check
    if _server_responds "$port"; then
        respond_status="${C_BGREEN}yes — accepting connections${C_RESET}"
    else
        respond_status="${C_BYELLOW}no — port not open yet (or server crashed)${C_RESET}"
    fi

    _header "Server Status — port ${port}"
    printf "\n"
    _detail "Status"       "$proc_status"
    _detail "Responding"   "$respond_status"
    _detail "Port"         "$port"
    _detail "Backend"      "$backend"
    _detail "PID"          "$pid"
    if [[ -n "$serve_file" ]]; then
        _detail "Serving"      "${dir}/${serve_file}"
    else
        _detail "Serving"      "$dir"
    fi
    _detail "Started"      "$started"
    _detail "Running Time" "$uptime"
    _detail "Local URL"    "${C_BGREEN}http://127.0.0.1:${port}${url_suffix}${C_RESET}"
    _detail "LAN URL"      "${C_BGREEN}http://${lan_ip}:${port}${url_suffix}${C_RESET}"
    _detail "Log File"     "$logfile"
    printf "\n"
}

# ---------------------------------------------------------------------------
# webshow
# ---------------------------------------------------------------------------

webshow() {
    _init_dirs || return 1

    local port="${1:-}"
    if [[ -z "$port" ]]; then
        _err "Usage: webshow <port>"
        return 1
    fi
    _validate_port "$port" || return 1
    _db_prune

    if ! _db_has "$port"; then
        _err "No webser-managed server found on port ${port}."
        _info "Run ${C_BWHITE}weblist${C_RESET} to see running servers."
        return 1
    fi

    local logfile
    logfile=$(_db_get "$port" 5)

    if [[ ! -f "$logfile" ]]; then
        _warn "Log file not found: ${logfile}"
        _info "The server may not have written any output yet."
        return 1
    fi

    printf "\n"
    _info "Streaming logs for server on port ${C_BWHITE}${port}${C_RESET}"
    printf "  ${C_DIM}Commands: ${C_BYELLOW}webhide${C_DIM} · ${C_BYELLOW}webstop${C_DIM} · ${C_BYELLOW}weblist${C_DIM} · ${C_BYELLOW}webstatus${C_RESET}\n"
    printf "\n"

    local div=""
    local i; for (( i=0; i<60; i++ )); do div+="─"; done
    printf "${C_BBLUE}%s${C_RESET}\n\n" "$div"

    # Show the last 20 lines of existing log before following
    if [[ -s "$logfile" ]]; then
        tail -n 20 "$logfile"
        printf "\n${C_DIM}%s (live)${C_RESET}\n\n" "$div"
    fi

    # Start tailing in background; capture its PID for cleanup
    tail -f "$logfile" &
    local tail_pid=$!

    # Ensure tail is always killed on function exit, Ctrl+C, or SIGTERM
    trap "
        kill ${tail_pid} 2>/dev/null
        wait ${tail_pid} 2>/dev/null
        trap - INT TERM EXIT
    " INT TERM EXIT

    # Interactive prompt loop
    local input
    while true; do
        printf "\n${C_BCYAN}→ ${C_RESET}"

        # Read one line; break on EOF (Ctrl+D)
        if ! IFS= read -r input 2>/dev/null; then
            printf "\n"
            break
        fi

        # Strip surrounding whitespace
        input="${input#"${input%%[![:space:]]*}"}"
        input="${input%"${input##*[![:space:]]}"}"

        case "$input" in
            webhide|exit|quit|q)
                printf "\n"
                break
                ;;
            webstop)
                kill "$tail_pid" 2>/dev/null
                wait "$tail_pid" 2>/dev/null
                trap - INT TERM EXIT
                printf "\n"
                webstop "$port"
                return 0
                ;;
            weblist)
                printf "\n"
                weblist
                ;;
            webstatus)
                printf "\n"
                webstatus "$port"
                ;;
            "")
                # Empty input — just re-show the prompt
                ;;
            *)
                printf "\n"
                _warn "Unknown command: '${input}'"
                printf "  ${C_DIM}Available: ${C_BYELLOW}webhide${C_DIM}  ${C_BYELLOW}webstop${C_DIM}  ${C_BYELLOW}weblist${C_DIM}  ${C_BYELLOW}webstatus${C_RESET}\n"
                ;;
        esac
    done

    # Cleanup tail process
    kill "$tail_pid" 2>/dev/null
    wait "$tail_pid" 2>/dev/null
    trap - INT TERM EXIT

    _info "Returned to terminal. Server on port ${port} is still running."
    _info "Use ${C_BWHITE}webstop ${port}${C_RESET} to stop it."
    printf "\n"
}

# ---------------------------------------------------------------------------
# webhide
# ---------------------------------------------------------------------------

webhide() {
    # When typed at a normal shell prompt (outside webshow), explain what it is.
    # Inside webshow, the input loop intercepts "webhide" before this runs.
    _warn "webhide exits the webshow log viewer."
    _info "Start a viewer first with: ${C_BWHITE}webshow <port>${C_RESET}"
}

# ---------------------------------------------------------------------------
# weblogs
# ---------------------------------------------------------------------------

weblogs() {
    _init_dirs || return 1

    local port="${1:-}"

    # --- List all log files ---
    if [[ -z "$port" ]]; then
        local files=()
        while IFS= read -r -d '' f; do
            files+=("$f")
        done < <(find "${WERSER_LOG_DIR}" -maxdepth 1 -name "webser_*.log" -print0 2>/dev/null | sort -z)

        if [[ ${#files[@]} -eq 0 ]]; then
            _info "No log files found in ${WERSER_LOG_DIR}"
            return 0
        fi

        printf "\n"
        _header "Log Files"
        printf "\n"

        local f size modified
        for f in "${files[@]}"; do
            size=$(du -sh "$f" 2>/dev/null | cut -f1)
            # GNU stat first, BSD date -r as fallback
            modified=$(stat -c "%y" "$f" 2>/dev/null | cut -d' ' -f1,2 | cut -d'.' -f1 \
                    || date -r "$f" "+%Y-%m-%d %H:%M" 2>/dev/null)
            printf "  ${C_BCYAN}%-40s${C_RESET}  %6s  %s\n" \
                "$(basename "$f")" "$size" "$modified"
        done
        printf "\n"
        _info "View a log: ${C_BWHITE}weblogs <port>${C_RESET}"
        printf "\n"
        return 0
    fi

    # --- Show log for a specific port ---
    _validate_port "$port" || return 1

    local logfile="${WERSER_LOG_DIR}/webser_${port}.log"

    if [[ ! -f "$logfile" ]]; then
        _err "No log file found for port ${port}: ${logfile}"
        _info "Run ${C_BWHITE}weblogs${C_RESET} to list all available log files."
        return 1
    fi

    if [[ ! -s "$logfile" ]]; then
        _info "Log file for port ${port} exists but is empty."
        return 0
    fi

    printf "\n"
    _header "Logs — port ${port}"
    printf "${C_DIM}File: %s${C_RESET}\n\n" "$logfile"
    cat "$logfile"
    printf "\n"
}

# ---------------------------------------------------------------------------
# webver  (v0.9)
# ---------------------------------------------------------------------------

webver() {
    _init_dirs || return 1

    local stored_ver
    stored_ver=$(cat "${WERSER_VERSION_FILE}" 2>/dev/null || echo "(not recorded)")

    _header "webser — Version Information"
    printf "\n"
    _detail "Script version"  "${WERSER_VERSION}"
    _detail "Config version"  "${stored_ver}"
    printf "\n"
    _detail "Config dir"      "${WERSER_CONFIG_DIR}"
    _detail "Log dir"         "${WERSER_LOG_DIR}"
    _detail "Database"        "${WERSER_DB}"
    _detail "Crash log"       "${WERSER_CRASH_LOG}"
    printf "\n"

    # Backend availability table
    printf "  ${C_BCYAN}Backends:${C_RESET}\n"

    local pybin pyver
    pybin=$(_python_bin)
    if [[ -n "$pybin" ]]; then
        pyver=$("$pybin" --version 2>&1 | head -1)
        printf "  ${C_BGREEN}✓${C_RESET}  python     %s\n" "$pyver"
    else
        printf "  ${C_DIM}✗  python     not installed${C_RESET}\n"
    fi

    if [[ -n "$pybin" ]] && _has_python_module "flask"; then
        local fver
        fver=$("$pybin" -c 'import flask; print(flask.__version__)' 2>/dev/null || echo "?")
        printf "  ${C_BGREEN}✓${C_RESET}  flask      %s\n" "$fver"
    else
        printf "  ${C_DIM}✗  flask      not installed${C_RESET}\n"
    fi

    if _has_binary busybox && busybox --list 2>/dev/null | grep -q "^httpd$"; then
        local bbver
        bbver=$(busybox --version 2>/dev/null | head -1)
        printf "  ${C_BGREEN}✓${C_RESET}  busybox    %s\n" "$bbver"
    else
        printf "  ${C_DIM}✗  busybox    httpd not available${C_RESET}\n"
    fi

    if _has_binary php; then
        local phpver
        phpver=$(php --version 2>/dev/null | head -1)
        printf "  ${C_BGREEN}✓${C_RESET}  php        %s\n" "$phpver"
    else
        printf "  ${C_DIM}✗  php        not installed${C_RESET}\n"
    fi

    if _has_node_httpserver; then
        local nodever
        nodever=$(http-server --version 2>/dev/null || echo "via npx")
        printf "  ${C_BGREEN}✓${C_RESET}  node       http-server %s\n" "$nodever"
    else
        printf "  ${C_DIM}✗  node       http-server not installed${C_RESET}\n"
    fi

    printf "\n"
}

# ---------------------------------------------------------------------------
# webclearlogs  (v0.8)
# ---------------------------------------------------------------------------

webclearlogs() {
    _init_dirs || return 1

    printf "\n"
    _info "Scanning log files..."
    printf "  ${C_DIM}Active server logs are skipped. User files are never touched.${C_RESET}\n\n"

    # Collect ports of currently running servers
    local running_ports
    running_ports=$(_db_list_ports)

    local deleted=0 skipped=0

    # Process all webser_*.log files (active port logs + rotated archives)
    local f port_from_file
    while IFS= read -r -d '' f; do
        local fname
        fname=$(basename "$f")

        # Extract port number from filename  webser_<port>.log  or
        # webser_<port>_<timestamp>.log
        port_from_file=$(printf '%s' "$fname" | grep -oE '^webser_([0-9]+)' | grep -oE '[0-9]+')

        # Rotated / archived logs (have a timestamp suffix) — always safe to delete
        if printf '%s' "$fname" | grep -qE '^webser_[0-9]+_[0-9]{8}_[0-9]{6}\.log$'; then
            rm -f "$f" && {
                _detail "Deleted (rotated)" "$fname"
                (( ++deleted ))
            }
            continue
        fi

        # Active log: skip if server is running on that port
        if [[ -n "$port_from_file" ]] && \
           printf '%s\n' "$running_ports" | grep -q "^${port_from_file}$"; then
            _detail "Skipped  (active)" "$fname"
            (( ++skipped ))
            continue
        fi

        rm -f "$f" && {
            _detail "Deleted" "$fname"
            (( ++deleted ))
        }
    done < <(find "${WERSER_LOG_DIR}" -maxdepth 1 -name "webser_*.log" -print0 2>/dev/null)

    # Clear the crash log too
    if [[ -f "${WERSER_CRASH_LOG}" && -s "${WERSER_CRASH_LOG}" ]]; then
        rm -f "${WERSER_CRASH_LOG}" && {
            _detail "Deleted" "crashes.log"
            (( ++deleted ))
        }
    fi

    printf "\n"
    if (( deleted == 0 && skipped == 0 )); then
        _ok "No log files found — nothing to clear."
    else
        _ok "Deleted ${deleted} file(s). Skipped ${skipped} (active server logs)."
    fi
    printf "\n"
}

# ---------------------------------------------------------------------------
# webclear  (v0.8)
# ---------------------------------------------------------------------------

webclear() {
    _init_dirs || return 1

    printf "\n"
    _info "Clearing temporary runtime files..."
    printf "  ${C_DIM}User files are never touched.${C_RESET}\n\n"

    local cleared=0

    # --- Remove stale Flask helper scripts (those whose port is not in DB) ---
    local running_ports port_from_script
    running_ports=$(_db_list_ports)

    local script
    while IFS= read -r -d '' script; do
        port_from_script=$(basename "$script" | grep -oE '[0-9]+')
        if ! printf '%s\n' "$running_ports" | grep -q "^${port_from_script}$"; then
            rm -f "$script" && {
                _detail "Removed" "$(basename "$script")"
                (( ++cleared ))
            }
        fi
    done < <(find "${WERSER_CONFIG_DIR}" -maxdepth 1 -name "flask_*.py" -print0 2>/dev/null)

    # --- Remove stale DB lock if its owner is no longer alive ---
    if [[ -d "${WERSER_LOCK}" ]]; then
        local lock_pid
        lock_pid=$(cat "${WERSER_LOCK}/pid" 2>/dev/null || true)
        if [[ -z "$lock_pid" ]] || ! kill -0 "$lock_pid" 2>/dev/null; then
            rm -rf "${WERSER_LOCK}" && {
                _detail "Removed" "stale DB lock"
                (( ++cleared ))
            }
        else
            _detail "Kept    " "DB lock (owner PID ${lock_pid} is alive)"
        fi
    fi

    # --- Prune dead DB entries ---
    local before after pruned
    before=$(grep -c '[^[:space:]]' "${WERSER_DB}" 2>/dev/null || echo 0)
    _db_prune
    after=$(grep -c '[^[:space:]]' "${WERSER_DB}" 2>/dev/null || echo 0)
    pruned=$(( before - after ))
    if (( pruned > 0 )); then
        _detail "Pruned" "${pruned} dead DB entry/entries"
        (( cleared += pruned ))
    fi

    # --- Remove leftover mktemp DB work files ---
    local tmp_file
    while IFS= read -r -d '' tmp_file; do
        rm -f "$tmp_file" && {
            _detail "Removed" "$(basename "$tmp_file")"
            (( ++cleared ))
        }
    done < <(find "${WERSER_CONFIG_DIR}" -maxdepth 1 -name "db.??????" -print0 2>/dev/null)

    printf "\n"
    if (( cleared == 0 )); then
        _ok "Nothing to clear — runtime directory is already clean."
    else
        _ok "Cleared ${cleared} temporary file(s)/entry/entries."
    fi
    printf "\n"
}

# ---------------------------------------------------------------------------
# ENTRY POINT
# (Only active when the script is executed directly, not when sourced)
# ---------------------------------------------------------------------------

_webser_main() {
    local cmd="${1:-}"
    shift || true

    # Light pre-flight check on every invocation
    _check_core_deps || return 1

    case "$cmd" in
        # Each command function calls _init_dirs internally;
        # the dispatcher does not duplicate that call.
        webstart)     webstart     "$@" ;;
        webmulti)     webmulti     "$@" ;;
        webstop)      webstop      "$@" ;;
        weblist)      weblist      "$@" ;;
        webstatus)    webstatus    "$@" ;;
        webshow)      webshow      "$@" ;;
        webhide)      webhide      "$@" ;;
        weblogs)      weblogs      "$@" ;;
        webclearlogs) webclearlogs "$@" ;;
        webclear)     webclear     "$@" ;;
        webver)       webver       "$@" ;;
        webhelp|help|--help|-h) webhelp ;;
        --version|-V|version)
            printf "webser %s\n" "${WERSER_VERSION}"
            ;;
        "")
            _err "No command given. Run: ${C_BWHITE}webhelp${C_RESET}"
            return 1
            ;;
        *)
            _err "Unknown command: '${cmd}'. Run: ${C_BWHITE}webhelp${C_RESET}"
            return 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # When invoked via a named symlink (e.g. webstart → webser),
    # treat the symlink name as the subcommand automatically.
    _self=$(basename "$0")
    case "$_self" in
        webstart|webmulti|webstop|weblist|webstatus|webshow|webhide|\
        weblogs|webclearlogs|webclear|webhelp|webver)
            # Invoked via a named command symlink — inject name as subcommand
            _webser_main "$_self" "$@" ;;
        *)
            # Invoked as "webser <cmd> [args]" or "webser --version"
            _webser_main "$@" ;;
    esac
fi
