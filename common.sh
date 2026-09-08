#!/bin/sh
# common.sh - shared setup for lab scripts.
# Do NOT execute this file directly, source it instead:
#   . "$(dirname "$0")/common.sh"

RED="$(printf '\033[0;31m')"
GREEN="$(printf '\033[0;32m')"
YELLOW="$(printf '\033[0;33m')"
BLUE="$(printf '\033[0;34m')"
CYAN="$(printf '\033[0;36m')"
BOLD="$(printf '\033[1m')"
RESET="$(printf '\033[0m')"

# Log helpers
log_info()    { printf "%s[info]%s %s\n" "$CYAN" "$RESET" "$1"; }
log_success() { printf "%s[ok]%s %s\n" "$GREEN" "$RESET" "$1"; }
log_warn()    { printf "%s[warn]%s %s\n" "$YELLOW" "$RESET" "$1"; }
log_error()   { printf "%s[error]%s %s\n" "$RED" "$RESET" "$1" >&2; }

# PS4 colorize 'set -x'
export PS4="${BLUE}+${RESET} "