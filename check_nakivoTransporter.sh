#!/usr/bin/env bash
#
# check_nakivoTransporterState.sh - Icinga/Nagios check of a specific Nakivo transporter state
#
# Repository:
#   https://github.com/Nemester/check-nakivo
#
# Description:
#   Checks the state of a specific Nakivo transporter and optionally evaluates
#   the current transporter load against warning and critical thresholds.
#
# Usage:
#   ./check_nakivoTransporterState.sh <transporter_id> [--warn-load <value>] [--crit-load <value>]
#
# Return codes:
#   OK        (0) Transporter state OK and load below thresholds
#   WARNING   (1) Transporter load exceeds warning threshold
#   CRITICAL  (2) Transporter state not OK or load exceeds critical threshold
#   UNKNOWN   (3) CLI errors, parsing issues, or invalid input
# 
# Changelog:
#   1.0 - Initial implementation
#   1.1 - Refactored for robustness and consistency

Author="Manuel Sonder"
Version="1.1"

set -o nounset
set -o pipefail

. /usr/lib/nagios/plugins/utils.sh

CONFIG_FILE="/etc/nagios/nakivo.conf"
CLI_BIN="/opt/nakivo/director/bin/cli.sh"

usage() {
    cat <<EOF

Version $Version

Usage:
  $0 <transporter_id> [--warn-load <value>] [--crit-load <value>]

Description:
  Checks a specific Nakivo transporter state and optionally evaluates
  current load against thresholds.

Threshold semantics:
  --warn-load  alert if current load is >= threshold
  --crit-load  alert if current load is >= threshold

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

die_critical() {
    printf '[CRITICAL]: %s\n' "$1"
    exit "$STATE_CRITICAL"
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die_unknown "Required command not found: $1"
}

is_number() {
    [[ "${1:-}" =~ ^[0-9]+$ ]]
}

validate_threshold() {
    local name="$1"
    local value="$2"

    if [[ -n "$value" ]] && ! is_number "$value"; then
        die_unknown "Invalid value for $name: '$value' (must be an integer)"
    fi
}

validate_threshold_pair_high_worse() {
    local warn_name="${1:-}"
    local warn_value="${2:-}"
    local crit_name="${3:-}"
    local crit_value="${4:-}"

    validate_threshold "$warn_name" "$warn_value"
    validate_threshold "$crit_name" "$crit_value"

    if [[ -n "$warn_value" && -n "$crit_value" && "$warn_value" -gt "$crit_value" ]]; then
        die_unknown "Invalid thresholds: $warn_name ($warn_value) must be <= $crit_name ($crit_value)"
    fi
}

extract_field_value() {
    local block="$1"
    local label="$2"

    awk -F ':' -v wanted="$label" '
        BEGIN { IGNORECASE=1 }
        $0 ~ "^[[:space:]]*" wanted "[[:space:]]*:" {
            val=$0
            sub(/^[^:]*:[[:space:]]*/, "", val)
            print val
            exit
        }
    ' <<< "$block"
}

sanitize_perf_label() {
    local s="$1"
    s="${s//[^a-zA-Z0-9_]/_}"
    printf '%s' "$s"
}

# --- Dependency checks ---
require_cmd awk
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
if [[ $# -lt 1 ]]; then
    usage
    exit "$STATE_UNKNOWN"
fi

TRANSPORTER_ID="$1"
shift

WARN_LOAD=""
CRIT_LOAD=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --warn-load)
            [[ $# -ge 2 ]] || die_unknown "Missing value for $1"
            WARN_LOAD="$2"
            shift 2
            ;;
        --crit-load)
            [[ $# -ge 2 ]] || die_unknown "Missing value for $1"
            CRIT_LOAD="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        --version|-v)
            echo "$Version"
            exit 0
            ;;
        *)
            die_unknown "Unknown parameter: $1"
            ;;
    esac
done

[[ -n "$TRANSPORTER_ID" ]] || die_unknown "No transporter ID provided"

validate_threshold_pair_high_worse "--warn-load" "$WARN_LOAD" "--crit-load" "$CRIT_LOAD"

# --- Fetch transporter data ---
if ! output="$("$CLI_BIN" -tri "$TRANSPORTER_ID" -u "$NAKIVO_USER" -pwd "$NAKIVO_PASS" -t "$NAKIVO_HOST" -p "$NAKIVO_PORT" 2>&1)"; then
    die_unknown "CLI exited with error: $output"
fi

[[ -n "$output" ]] || die_unknown "CLI returned empty output"

# --- Parse output ---
ID="$(extract_field_value "$output" "ID")"
HOST="$(extract_field_value "$output" "IP/Hostname")"
CUR_LOAD="$(extract_field_value "$output" "Current load")"
MAX_LOAD="$(extract_field_value "$output" "Max load")"
STATE_VAL="$(extract_field_value "$output" "State")"
STATUS="$(extract_field_value "$output" "Status")"

[[ -n "$ID" ]] || die_unknown "Failed to parse transporter ID"
[[ -n "$HOST" ]] || HOST="unknown"
[[ -n "$STATE_VAL" ]] || die_unknown "Failed to parse transporter state"
[[ -n "$STATUS" ]] || STATUS="unknown"
[[ -n "$CUR_LOAD" ]] || die_unknown "Failed to parse current transporter load"
[[ -n "$MAX_LOAD" ]] || die_unknown "Failed to parse maximum transporter load"

if ! is_number "$CUR_LOAD"; then
    die_unknown "Parsed current load is not numeric: '$CUR_LOAD'"
fi

if ! is_number "$MAX_LOAD"; then
    die_unknown "Parsed max load is not numeric: '$MAX_LOAD'"
fi

# --- Check transporter state ---
if [[ "${STATE_VAL,,}" != "ok" ]]; then
    die_critical "Transporter $ID ($HOST) state is $STATE_VAL, status: $STATUS"
fi

# --- Evaluate load thresholds ---
EXIT_CODE=$STATE_OK
MSG="OK"

if [[ -n "$CRIT_LOAD" && "$CUR_LOAD" -ge "$CRIT_LOAD" ]]; then
    MSG="CRITICAL"
    EXIT_CODE=$STATE_CRITICAL
elif [[ -n "$WARN_LOAD" && "$CUR_LOAD" -ge "$WARN_LOAD" ]]; then
    MSG="WARNING"
    EXIT_CODE=$STATE_WARNING
fi

# --- Output ---
safe_id="$(sanitize_perf_label "$ID")"
printf '[%s]: Transporter %s (%s), load: %s/%s, state: %s, status: %s | transporter-%s-load=%s;%s;%s;0;%s\n' \
    "$MSG" "$ID" "$HOST" "$CUR_LOAD" "$MAX_LOAD" "$STATE_VAL" "$STATUS" \
    "$safe_id" "$CUR_LOAD" "$WARN_LOAD" "$CRIT_LOAD" "$MAX_LOAD"

exit "$EXIT_CODE"