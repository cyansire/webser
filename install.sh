#!/usr/bin/env bash
# =============================================================================
# install.sh — webser Installer for Termux
# =============================================================================
# Usage:
#   bash install.sh                   Install to ~/.local/bin  (default)
#   bash install.sh --prefix <path>   Install to <path>/bin
#   bash install.sh --uninstall       Remove all installed files
#
# What this does:
#   1. Copies webser.sh to <prefix>/bin/webser
#   2. Creates command symlinks (webstart, webstop, weblist, …)
#   3. Offers to add shell integration to ~/.bashrc / ~/.zshrc
#
# Nothing outside <prefix>/bin is written without asking.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEBSER_SH="${SCRIPT_DIR}/webser.sh"

PREFIX="${HOME}/.local"
UNINSTALL=0

COMMANDS=(
    webstart webmulti webstop weblist webstatus
    webshow webhide weblogs webclearlogs
    webclear webhelp webver
)

# ---------------------------------------------------------------------------
# Colour helpers (same palette as webser.sh)
# ---------------------------------------------------------------------------

C_RESET="\033[0m"
C_BGREEN="\033[1;32m"
C_BRED="\033[1;31m"
C_BCYAN="\033[1;36m"
C_BYELLOW="\033[1;33m"
C_BWHITE="\033[1;37m"
C_DIM="\033[2m"

_info() { printf "${C_BCYAN}[*]${C_RESET} %s\n"   "$*"; }
_ok()   { printf "${C_BGREEN}[✓]${C_RESET} %s\n"  "$*"; }
_warn() { printf "${C_BYELLOW}[!]${C_RESET} %s\n" "$*" >&2; }
_err()  { printf "${C_BRED}[✗]${C_RESET} %s\n"    "$*" >&2; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix)
            if [[ -z "${2:-}" ]]; then
                _err "--prefix requires a path."
                exit 1
            fi
            PREFIX="$2"; shift 2
            ;;
        --uninstall) UNINSTALL=1; shift ;;
        --help|-h)
            cat <<EOF

  Usage:
    bash install.sh                   Install to ~/.local/bin
    bash install.sh --prefix <path>   Custom prefix
    bash install.sh --uninstall       Remove all installed files

EOF
            exit 0
            ;;
        *)
            _err "Unknown argument: '$1'"
            exit 1
            ;;
    esac
done

BIN_DIR="${PREFIX}/bin"
INSTALL_TARGET="${BIN_DIR}/webser"

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

if [[ $UNINSTALL -eq 1 ]]; then
    printf "\n"
    _info "Uninstalling webser from ${BIN_DIR}..."
    printf "\n"

    local_removed=0

    if [[ -f "${INSTALL_TARGET}" ]]; then
        rm -f "${INSTALL_TARGET}"
        _ok "Removed ${INSTALL_TARGET}"
        (( local_removed++ ))
    fi

    for cmd in "${COMMANDS[@]}"; do
        link="${BIN_DIR}/${cmd}"
        if [[ -L "$link" ]]; then
            rm -f "$link"
            _ok "Removed symlink: ${cmd}"
            (( local_removed++ ))
        fi
    done

    if (( local_removed == 0 )); then
        _warn "Nothing to uninstall in ${BIN_DIR}."
    else
        printf "\n"
        _ok "Uninstall complete."
        _warn "Shell integration lines (if any) must be removed manually from ~/.bashrc / ~/.zshrc."
    fi
    printf "\n"
    exit 0
fi

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------

printf "\n"
_info "webser installer"
printf "  ${C_DIM}Installing to: ${C_BWHITE}${BIN_DIR}${C_RESET}\n\n"

if [[ ! -f "$WEBSER_SH" ]]; then
    _err "webser.sh not found at: ${WEBSER_SH}"
    exit 1
fi

if ! bash -n "$WEBSER_SH" 2>/dev/null; then
    _err "webser.sh has a syntax error — aborting."
    exit 1
fi

# Create bin dir if needed
mkdir -p "$BIN_DIR" || {
    _err "Cannot create directory: ${BIN_DIR}"
    exit 1
}

# Warn if BIN_DIR is not in PATH
if ! printf '%s\n' "${PATH//:/$'\n'}" | grep -qxF "$BIN_DIR"; then
    _warn "${BIN_DIR} is not in your PATH."
    printf "  ${C_DIM}Add this to ~/.bashrc or ~/.zshrc:${C_RESET}\n"
    printf "    ${C_BYELLOW}export PATH=\"\$HOME/.local/bin:\$PATH\"${C_RESET}\n\n"
fi

# ---------------------------------------------------------------------------
# Install main script
# ---------------------------------------------------------------------------

install -m 755 "$WEBSER_SH" "$INSTALL_TARGET"
_ok "Installed: ${INSTALL_TARGET}"

# ---------------------------------------------------------------------------
# Create command symlinks
# ---------------------------------------------------------------------------

printf "\n"
_info "Creating command symlinks..."
for cmd in "${COMMANDS[@]}"; do
    link="${BIN_DIR}/${cmd}"
    ln -sf "$INSTALL_TARGET" "$link"
    _ok "  ${cmd} → webser"
done

# ---------------------------------------------------------------------------
# Optional shell integration (source for interactive functions)
# ---------------------------------------------------------------------------

printf "\n"
_info "Shell integration (optional)"
printf "  ${C_DIM}The symlinks above let you run all commands directly.${C_RESET}\n"
printf "  ${C_DIM}If you source webser instead, the functions load into your shell${C_RESET}\n"
printf "  ${C_DIM}and work in the current session without subshells.${C_RESET}\n\n"

read -rp "  Add 'source ${INSTALL_TARGET}' to your shell RC file? [y/N] " ans
case "${ans,,}" in
    y|yes)
        rc_file=""
        if [[ -n "${ZSH_VERSION:-}" ]] || [[ "${SHELL:-}" == */zsh ]]; then
            rc_file="${HOME}/.zshrc"
        else
            rc_file="${HOME}/.bashrc"
        fi

        source_line="source \"${INSTALL_TARGET}\"  # webser"

        if grep -qF "$source_line" "$rc_file" 2>/dev/null; then
            _warn "Already present in ${rc_file} — skipping."
        else
            printf '\n%s\n' "$source_line" >> "$rc_file"
            _ok "Added to ${rc_file}"
            _info "Run: source ${rc_file}  (or open a new terminal)"
        fi
        ;;
    *)
        _info "Skipped. Run commands via symlinks or source manually."
        ;;
esac

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

printf "\n"
_ok "webser v$(grep -m1 'WERSER_VERSION=' "${INSTALL_TARGET}" | grep -oE '[0-9.]+') installed."
printf "\n"
printf "  ${C_BCYAN}Quick start:${C_RESET}\n"
printf "    ${C_BWHITE}webstart 8080${C_RESET}          serve current directory\n"
printf "    ${C_BWHITE}weblist${C_RESET}                see all running servers\n"
printf "    ${C_BWHITE}webstop 8080${C_RESET}           stop a server\n"
printf "    ${C_BWHITE}webhelp${C_RESET}                full command reference\n"
printf "\n"
