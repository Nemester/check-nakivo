#!/usr/bin/env bash
#
# check_nakivoRepoState.sh - Icinga/Nagios check of a specific Nakivo repo state
#
# Repository:
#   https://github.com/Nemester/check-nakivo
#
# Description:
#   Checks the state of a specific Nakivo repository and returns perfdata for:
#     - number of backups
#     - free size
#     - allocated size
#     - reclaimable size
#
# Usage:
#   ./check_nakivoRepoState.sh <repo_name> \
#       [--warn-reclaim <GB>] [--crit-reclaim <GB>] \
#       [--warn-free <GB>]    [--crit-free <GB>] \
#       [--warn-alloc <GB>]   [--crit-alloc <GB>]
#
# Return codes:
#   OK        (0) Repository accessible and within thresholds
#   WARNING   (1) Thresholds exceeded (non-critical)
#   CRITICAL  (2) Repository not accessible or critical thresholds exceeded
#   UNKNOWN   (3) CLI errors, parsing issues, or invalid input
# 
# Changelog:
#   1.0 - Initial implementation
#   1.1 - Added perfdata to output
#   1.2 - Adapted for single-repo check via parameter
#   1.3 - Added support thresholds
#   1.4 - Refactored for robustness and validation

Author="Manuel Sonder"
Version="1.4"

set -o nounset
set -o pipefail

. /usr/lib/nagios/plugins/utils.sh

CONFIG_FILE="/etc/nagios/nakivo.conf"
CLI_BIN="/opt/nakivo/director/bin/cli.sh"

usage() {
    cat <<EOF

Version $Version

Usage:
  $0 <repo_name> [--warn-reclaim <GB>] [--crit-reclaim <GB>] [--warn-free <GB>] [--crit-free <GB>] [--warn-alloc <GB>] [--crit-alloc <GB>]

Description:
  Check a specific Nakivo repository state and return perfdata.

Threshold semantics:
  --warn-reclaim / --crit-reclaim : alert if reclaimable space is >= threshold
  --warn-free    / --crit-free    : alert if free space is <= threshold
  --warn-alloc   / --crit-alloc   : alert if allocated space is >= threshold

Return codes:
  OK        (0) Repository accessible and within thresholds
  WARNING   (1) Thresholds exceeded (non-critical)
  CRITICAL  (2) Repository not accessible or critical thresholds exceeded
  UNKNOWN   (3) CLI errors, parsing issues, or invalid input

EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi

if [[ "${1:-}" == "--version" || "${1:-}" == "-v" ]]; then
    echo $Version
    exit 0
fi

die_unknown() {
    printf 'UNKNOWN: %s\n' "$1"
    exit "$STATE_UNKNOWN"
}

die_critical() {
    printf 'CRITICAL: %s\n' "$1"
    exit "$STATE_CRITICAL"
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die_unknown "Required command not found: $1"
}

is_number() {
    [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

validate_threshold() {
    local name="$1"
    local value="$2"

    if [[ -n "$value" ]] && ! is_number "$value"; then
        die_unknown "Invalid value for $name: '$value' (must be numeric)"
    fi
}

validate_threshold_pair_high_worse() {
    local warn_name="${1:-}"
    local warn_value="${2:-}"
    local crit_name="${3:-}"
    local crit_value="${4:-}"

    validate_threshold "$warn_name" "$warn_value"
    validate_threshold "$crit_name" "$crit_value"

    if [[ -n "$warn_value" && -n "$crit_value" ]]; then
        awk -v w="$warn_value" -v c="$crit_value" 'BEGIN { exit (w > c ? 0 : 1) }'
        if [[ $? -eq 0 ]]; then
            die_unknown "Invalid thresholds: $warn_name ($warn_value) must be <= $crit_name ($crit_value)"
        fi
    fi
}

validate_threshold_pair_low_worse() {
    local warn_name="${1:-}"
    local warn_value="${2:-}"
    local crit_name="${3:-}"
    local crit_value="${4:-}"

    validate_threshold "$warn_name" "$warn_value"
    validate_threshold "$crit_name" "$crit_value"

    if [[ -n "$warn_value" && -n "$crit_value" ]]; then
        awk -v w="$warn_value" -v c="$crit_value" 'BEGIN { exit (w < c ? 0 : 1) }'
        if [[ $? -eq 0 ]]; then
            die_unknown "Invalid thresholds: $warn_name ($warn_value) must be >= $crit_name ($crit_value)"
        fi
    fi
}

sanitize_perf_label() {
    local s="$1"
    s="${s//[^a-zA-Z0-9_]/_}"
    printf '%s' "$s"
}

extract_repo_block() {
    local all_output="$1"
    local target_repo="$2"

    awk -v repo="$target_repo" '
        BEGIN {
            found=0
        }

        /^[[:space:]]*Name[[:space:]]*:/ {
            current=$0
            sub(/^[^:]*:[[:space:]]*/, "", current)

            if (current == repo) {
                found=1
                print
                next
            }

            found=0
        }

        found { print }
    ' <<< "$all_output"
}

extract_field_value() {
    local block="$1"
    local label="$2"

    awk -v wanted="$label" '
        BEGIN { IGNORECASE=1 }
        $0 ~ "^[[:space:]]*" wanted "[[:space:]]*:" {
            val=$0
            sub(/^[^:]*:[[:space:]]*/, "", val)
            print val
            exit
        }
    ' <<< "$block"
}

# --- Dependency checks ---
require_cmd awk
require_cmd grep
require_cmd sed
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

REPO_NAME="$1"
shift

WARN_RECLAIM=""
CRIT_RECLAIM=""
WARN_FREE=""
CRIT_FREE=""
WARN_ALLOC=""
CRIT_ALLOC=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --warn-reclaim)
            [[ $# -ge 2 ]] || die_unknown "Missing value for $1"
            WARN_RECLAIM="$2"
            shift 2
            ;;
        --crit-reclaim)
            [[ $# -ge 2 ]] || die_unknown "Missing value for $1"
            CRIT_RECLAIM="$2"
            shift 2
            ;;
        --warn-free)
            [[ $# -ge 2 ]] || die_unknown "Missing value for $1"
            WARN_FREE="$2"
            shift 2
            ;;
        --crit-free)
            [[ $# -ge 2 ]] || die_unknown "Missing value for $1"
            CRIT_FREE="$2"
            shift 2
            ;;
        --warn-alloc)
            [[ $# -ge 2 ]] || die_unknown "Missing value for $1"
            WARN_ALLOC="$2"
            shift 2
            ;;
        --crit-alloc)
            [[ $# -ge 2 ]] || die_unknown "Missing value for $1"
            CRIT_ALLOC="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            die_unknown "Unknown parameter: $1"
            ;;
    esac
done

[[ -n "$REPO_NAME" ]] || die_unknown "No repository name provided"

validate_threshold_pair_high_worse "--warn-reclaim" "$WARN_RECLAIM" "--crit-reclaim" "$CRIT_RECLAIM"
validate_threshold_pair_low_worse  "--warn-free"    "$WARN_FREE"    "--crit-free"    "$CRIT_FREE"
validate_threshold_pair_high_worse "--warn-alloc"   "$WARN_ALLOC"   "--crit-alloc"   "$CRIT_ALLOC"

# --- Fetch repository data ---
if ! output="$("$CLI_BIN" -rl -u "$NAKIVO_USER" -pwd "$NAKIVO_PASS" -t "$NAKIVO_HOST" -p "$NAKIVO_PORT" 2>&1)"; then
    die_unknown "CLI exited with error: $output"
fi

[[ -n "$output" ]] || die_unknown "CLI returned empty output"

repo_block="$(extract_repo_block "$output" "$REPO_NAME")"

if [[ -z "$repo_block" ]]; then
    die_critical "Repository '$REPO_NAME' not found"
fi

attached="$(extract_field_value "$repo_block" "Attached" | tr '[:upper:]' '[:lower:]')"
state="$(extract_field_value "$repo_block" "State" | tr '[:upper:]' '[:lower:]')"

if [[ "$attached" != "yes" ]]; then
    die_critical "Repository '$REPO_NAME' is not attached"
fi

if [[ "$state" != "ok" ]]; then
    die_critical "Repository '$REPO_NAME' is not accessible (state: ${state:-unknown})"
fi

# --- Parse repo metrics and build result ---
processed_output="$(
awk \
    -v name="$REPO_NAME" \
    -v wr="$WARN_RECLAIM" -v cr="$CRIT_RECLAIM" \
    -v wf="$WARN_FREE"    -v cf="$CRIT_FREE" \
    -v wa="$WARN_ALLOC"   -v ca="$CRIT_ALLOC" '
    function convert_to_gb(value, unit, u) {
        gsub(/,/, "", value)
        u = toupper(unit)

        if (u == "TB" || u == "TIB") return value * 1024
        if (u == "GB" || u == "GIB") return value
        if (u == "MB" || u == "MIB") return value / 1024
        if (u == "KB" || u == "KIB") return value / (1024 * 1024)
        if (u == "B") return value / (1024 * 1024 * 1024)

        return -1
    }

    function sanitize(s) {
        gsub(/[^a-zA-Z0-9_]/, "_", s)
        return s
    }

    function isnum(x) {
        return x ~ /^[0-9]+([.][0-9]+)?$/
    }

    BEGIN {
        backups = 0
        free_gb = -1
        alloc_gb = -1
        reclaim_gb = -1
        seen_status = 0
    }

    {
        line = $0

        if (match(line, /([0-9.]+)[[:space:]]+backups/)) {
            tmp = substr(line, RSTART, RLENGTH)
            sub(/[[:space:]]+backups$/, "", tmp)
            backups = tmp + 0
        }

        if (match(line, /([0-9.]+)[[:space:]]+([A-Za-z]+)[[:space:]]+free/)) {
            tmp = substr(line, RSTART, RLENGTH)
            if (match(tmp, /([0-9.]+)[[:space:]]+([A-Za-z]+)[[:space:]]+free/)) {
                num = substr(tmp, RSTART, RLENGTH)
                sub(/[[:space:]]+[A-Za-z]+[[:space:]]+free$/, "", num)

                unit = tmp
                sub(/^[0-9.]+[[:space:]]+/, "", unit)
                sub(/[[:space:]]+free$/, "", unit)

                free_gb = convert_to_gb(num, unit)
            }
        }

        if (match(line, /([0-9.]+)[[:space:]]+([A-Za-z]+)[[:space:]]+allocated/)) {
            tmp = substr(line, RSTART, RLENGTH)
            if (match(tmp, /([0-9.]+)[[:space:]]+([A-Za-z]+)[[:space:]]+allocated/)) {
                num = substr(tmp, RSTART, RLENGTH)
                sub(/[[:space:]]+[A-Za-z]+[[:space:]]+allocated$/, "", num)

                unit = tmp
                sub(/^[0-9.]+[[:space:]]+/, "", unit)
                sub(/[[:space:]]+allocated$/, "", unit)

                alloc_gb = convert_to_gb(num, unit)
            }
        }

        if (match(line, /([0-9.]+)[[:space:]]+([A-Za-z]+)[[:space:]]+can[[:space:]]+be[[:space:]]+reclaimed/)) {
            tmp = substr(line, RSTART, RLENGTH)
            if (match(tmp, /([0-9.]+)[[:space:]]+([A-Za-z]+)[[:space:]]+can[[:space:]]+be[[:space:]]+reclaimed/)) {
                num = substr(tmp, RSTART, RLENGTH)
                sub(/[[:space:]]+[A-Za-z]+[[:space:]]+can[[:space:]]+be[[:space:]]+reclaimed$/, "", num)

                unit = tmp
                sub(/^[0-9.]+[[:space:]]+/, "", unit)
                sub(/[[:space:]]+can[[:space:]]+be[[:space:]]+reclaimed$/, "", unit)

                reclaim_gb = convert_to_gb(num, unit)
            }
        }

        if (line ~ /^[[:space:]]*Status[[:space:]]*:/) {
            seen_status = 1
        }
    }

    END {
        safe_name = sanitize(name)
        status = "OK"
        exit_code = 0

        if (!seen_status) {
            print "UNKNOWN: Could not parse repository status block"
            exit 3
        }

        if (free_gb < 0 || alloc_gb < 0 || reclaim_gb < 0) {
            print "UNKNOWN: Failed to parse one or more repository metrics"
            exit 3
                }
        # reclaimable: higher is worse
        if (isnum(cr) && (reclaim_gb + 0) >= (cr + 0)) {
            status = "CRITICAL"
            exit_code = 2
        } else if (isnum(wr) && (reclaim_gb + 0) >= (wr + 0) && exit_code < 2) {
            status = "WARNING"
            exit_code = 1
        }

        # free: lower is worse
        if (isnum(cf) && (free_gb + 0) <= (cf + 0)) {
            status = "CRITICAL"
            exit_code = 2
        } else if (isnum(wf) && (free_gb + 0) <= (wf + 0) && exit_code < 2) {
            status = "WARNING"
            exit_code = 1
        }

        # allocated: higher is worse
        if (isnum(ca) && (alloc_gb + 0) >= (ca + 0)) {
            status = "CRITICAL"
            exit_code = 2
        } else if (isnum(wa) && (alloc_gb + 0) >= (wa + 0) && exit_code < 2) {
            status = "WARNING"
            exit_code = 1
        }

        printf "%s [%s]: %.0f backups, %.2f GB free, %.2f GB allocated, %.2f GB reclaimable | ", name, status, backups, free_gb, alloc_gb, reclaim_gb
        printf "%s_backups=%.0f;;;; ", safe_name, backups
        printf "%s_free_gb=%.2f;%s;%s;; ", safe_name, free_gb, wf, cf
        printf "%s_allocated_gb=%.2f;%s;%s;; ", safe_name, alloc_gb, wa, ca
        printf "%s_reclaimable_gb=%.2f;%s;%s;;\n", safe_name, reclaim_gb, wr, cr
        exit exit_code
    }
' <<< "$repo_block"
)"

exit_code=$?
printf '%s\n' "$processed_output"
exit "$exit_code"