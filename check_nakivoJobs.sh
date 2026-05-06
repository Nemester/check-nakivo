#!/usr/bin/env bash
#
# check_nakivoJobs.sh - Icinga/Nagios check of Nakivo job states
#
# Repository:
#   https://github.com/Nemester/check-nakivo
#
# Description:
#   Checks all Nakivo jobs and evaluates their last execution result.
#   The overall plugin state is determined as follows:
#     - all jobs successful              -> OK
#     - at least one job never executed  -> WARNING
#     - at least one failed/other state  -> CRITICAL
#
# Usage:
#   ./check_nakivoJobs.sh [--help] [--version]
#
# Return codes:
#   OK        (0) Transporter state OK and load below thresholds
#   WARNING   (1) Transporter load exceeds warning threshold
#   CRITICAL  (2) Transporter state not OK or load exceeds critical threshold
#   UNKNOWN   (3) CLI errors, parsing issues, or invalid input
#
# Changelog:
#   1.0 - Initial implementation
#   1.1 - Basic job state evaluation
#   1.2 - Improved output formatting
#   1.3 - Refactored for robustness and consistency

Author="Manuel Sonder"
Version="1.3"

set -o nounset
set -o pipefail

. /usr/lib/nagios/plugins/utils.sh

CONFIG_FILE="/etc/nagios/nakivo.conf"
CLI_BIN="/opt/nakivo/director/bin/cli.sh"

usage() {
    cat <<EOF

Version $Version

Usage:
  $0 [--help] [--version]

Description:
  Checks all Nakivo jobs and evaluates their last execution state.

Return codes:
  OK        (0) Transporter state OK and load below thresholds
  WARNING   (1) Transporter load exceeds warning threshold
  CRITICAL  (2) Transporter state not OK or load exceeds critical threshold
  UNKNOWN   (3) CLI errors, parsing issues, or invalid input

EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi

if [[ "${1:-}" == "--version" || "${1:-}" == "-v" ]]; then
    echo "$Version"
    exit 0
fi

die_unknown() {
    printf '[UNKNOWN]: %s\n' "$1"
    exit "$STATE_UNKNOWN"
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die_unknown "Required command not found: $1"
}

trim() {
    local value="${1:-}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

# --- Dependency checks ---
require_cmd awk
require_cmd tail
require_cmd tr
require_cmd "$CLI_BIN"

# --- Config checks ---
[[ -r "$CONFIG_FILE" ]] || die_unknown "Config file not readable: $CONFIG_FILE"
# shellcheck disable=SC1090
. "$CONFIG_FILE"

: "${NAKIVO_USER:?Missing NAKIVO_USER in $CONFIG_FILE}"
: "${NAKIVO_PASS:?Missing NAKIVO_PASS in $CONFIG_FILE}"
: "${NAKIVO_HOST:?Missing NAKIVO_HOST in $CONFIG_FILE}"
: "${NAKIVO_PORT:?Missing NAKIVO_PORT in $CONFIG_FILE}"

# --- Argument parsing ---
if [[ $# -gt 0 ]]; then
    die_unknown "Unknown parameter: $1"
fi

# --- Fetch job data ---
if ! output="$("$CLI_BIN" -jl -u "$NAKIVO_USER" -pwd "$NAKIVO_PASS" -t "$NAKIVO_HOST" -p "$NAKIVO_PORT" 2>&1)"; then
    die_unknown "CLI exited with error: $output"
fi

[[ -n "$output" ]] || die_unknown "CLI returned empty output"

if [[ "$output" == "no items" ]]; then
    die_unknown "No jobs found"
fi

jobs_output="$(printf '%s\n' "$output" | tail -n +2)"
[[ -n "$jobs_output" ]] || die_unknown "No job entries found after header"

# --- Evaluate job states ---
msg=""
rstate=$STATE_OK

while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    IFS='|' read -r id name state last <<< "$line"

    id="$(trim "$id")"
    name="$(trim "$name")"
    state="$(trim "$state")"
    last="$(trim "$last")"

    [[ -n "$id" ]] || continue
    [[ -n "$name" ]] || name="unknown"

    last_norm="$(printf '%s' "$last" | tr '[:upper:]' '[:lower:]')"

    case "$last_norm" in
        "successful")
            msg+="${msg:+; }ID $id | $name | OK"
            ;;
        "has not been executed yet")
            msg+="${msg:+; }ID $id | $name | PENDING"
            if [[ "$rstate" -lt "$STATE_WARNING" ]]; then
                rstate=$STATE_WARNING
            fi
            ;;
        *)
            msg+="${msg:+; }ID $id | $name | CRITICAL"
            rstate=$STATE_CRITICAL
            ;;
    esac
done <<< "$jobs_output"

[[ -n "$msg" ]] || die_unknown "No parsable job entries found"

# --- Final output ---
if [[ "$rstate" -eq "$STATE_OK" ]]; then
    printf '[OK]: %s\n' "$msg"
elif [[ "$rstate" -eq "$STATE_WARNING" ]]; then
    printf '[WARNING]: %s\n' "$msg"
elif [[ "$rstate" -eq "$STATE_CRITICAL" ]]; then
    printf '[CRITICAL]: %s\n' "$msg"
else
    die_unknown "Unexpected return state"
fi

exit "$rstate"