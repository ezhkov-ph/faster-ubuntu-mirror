#!/usr/bin/env bash
# faster-ubuntu-mirror — safely select and apply a fast Ubuntu archive mirror.

set -Eeuo pipefail
IFS=$'\n\t'

readonly PROGRAM_NAME="faster-ubuntu-mirror"
readonly DEFAULT_TEST_SIZE_KB=100
readonly DEFAULT_TEST_RUNS=3
readonly DEFAULT_TOP_LIMIT=10
# Canonical's mirror index is served over HTTP. Some networks cannot establish
# a TLS connection to this endpoint even when its HTTP service is reachable.
readonly MIRRORS_INDEX="http://mirrors.ubuntu.com"

COUNTRIES=()
TEST_SIZE_KB="$DEFAULT_TEST_SIZE_KB"
TEST_RUNS="$DEFAULT_TEST_RUNS"
MIRROR_COUNT=1
AUTO_SELECT=false
DRY_RUN=false
FORCE_LEGACY=false
SKIP_APT_UPDATE=false
SOURCE_FILE=""
SOURCE_FORMAT=""
CODENAME=""
WORK_DIR=""
BACKUP_FILE=""
PROBE_FILE=""
PROBE_SIZE=0

usage() {
    cat <<'EOF'
Usage: run.sh [options]

Finds responsive Ubuntu archive mirrors and, after confirmation, replaces the
Ubuntu archive URI in the active APT source file. A backup is always created
before a real change. If apt-get update fails, the backup is restored.

Options:
  -c, --country CC [CC ...]  Use mirrors registered for ISO country codes.
                              Without this option, use the official
                              IP-aware mirrors.txt index.
  -n, --number N             Select up to N fastest mirrors (default: 1).
                              In legacy sources.list mode only the first is
                              applied, because that format has one URI/line.
  -s, --size KB              Maximum package payload sampled in KiB (default: 100).
  -r, --runs N               Benchmark rounds per mirror (default: 3); rank by median.
  -a, --auto, --auto-select  Select the fastest mirror(s) without prompting.
      --dry-run              Show the resulting file; do not change the system.
  -L, --legacy               Force /etc/apt/sources.list mode.
      --no-apt-update        Do not verify the changed source with apt-get update.
  -h, --help                 Show this help.

Examples:
  ./run.sh --dry-run
  sudo ./run.sh -c DE FR --auto
  sudo ./run.sh -n 2 -c JP US
EOF
}

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
warn() { printf 'Warning: %s\n' "$*" >&2; }

cleanup() {
    [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] && rm -rf -- "$WORK_DIR"
    return 0
}
trap cleanup EXIT

require_commands() {
    local command_name
    for command_name in awk curl diff dpkg grep gzip mktemp sort; do
        command -v "$command_name" >/dev/null 2>&1 || die "Required command not found: $command_name"
    done
}

parse_args() {
    local countries_before
    while (($#)); do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            -c|--country)
                shift
                (($#)) || die "--country requires at least one country code"
                countries_before=${#COUNTRIES[@]}
                while (($#)) && [[ "$1" != -* ]]; do
                    [[ "$1" =~ ^[[:alpha:]]{2}$ ]] || die "Invalid country code: $1"
                    COUNTRIES+=("${1^^}")
                    shift
                done
                ((${#COUNTRIES[@]} > countries_before)) || die "--country requires at least one country code"
                continue
                ;;
            -n|--number)
                shift; (($#)) || die "--number requires a value"
                [[ "$1" =~ ^[1-9][0-9]*$ ]] || die "--number must be a positive integer"
                MIRROR_COUNT="$1"
                ;;
            -s|--size)
                shift; (($#)) || die "--size requires a value"
                [[ "$1" =~ ^[1-9][0-9]*$ ]] || die "--size must be a positive integer"
                TEST_SIZE_KB="$1"
                ;;
            -r|--runs)
                shift; (($#)) || die "--runs requires a value"
                [[ "$1" =~ ^[1-9][0-9]*$ ]] || die "--runs must be a positive integer"
                TEST_RUNS="$1"
                ;;
            -a|--auto|--auto-select) AUTO_SELECT=true ;;
            --dry-run) DRY_RUN=true ;;
            -L|--legacy) FORCE_LEGACY=true ;;
            --no-apt-update) SKIP_APT_UPDATE=true ;;
            *) die "Unknown option: $1" ;;
        esac
        shift
    done
}

detect_ubuntu() {
    [[ -r /etc/os-release ]] || die "/etc/os-release was not found"
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${ID:-}" == "ubuntu" ]] || die "This script supports Ubuntu only (detected: ${PRETTY_NAME:-unknown})"
    CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
    [[ -n "$CODENAME" ]] || die "Could not determine the Ubuntu codename"
}

detect_source_file() {
    if "$FORCE_LEGACY"; then
        SOURCE_FILE="/etc/apt/sources.list"
        SOURCE_FORMAT="legacy"
    elif [[ -f /etc/apt/sources.list.d/ubuntu.sources ]]; then
        SOURCE_FILE="/etc/apt/sources.list.d/ubuntu.sources"
        SOURCE_FORMAT="deb822"
    elif [[ -f /etc/apt/sources.list ]]; then
        SOURCE_FILE="/etc/apt/sources.list"
        SOURCE_FORMAT="legacy"
    else
        die "Could not find ubuntu.sources or sources.list"
    fi
    [[ -r "$SOURCE_FILE" ]] || die "Cannot read $SOURCE_FILE"
}

fetch_mirrors() {
    local list_file="$WORK_DIR/mirrors.raw" country url
    : >"$list_file"
    if ((${#COUNTRIES[@]} == 0)); then
        url="$MIRRORS_INDEX/mirrors.txt"
        printf 'Using the IP-aware Ubuntu mirror index.\n'
        curl --fail --location --silent --show-error "$url" >>"$list_file" || die "Could not fetch $url"
    else
        for country in "${COUNTRIES[@]}"; do
            url="$MIRRORS_INDEX/$country.txt"
            printf 'Fetching mirrors for %s.\n' "$country"
            curl --fail --location --silent --show-error "$url" >>"$list_file" || die "Could not fetch $url"
        done
    fi

    awk '
        { sub(/\r$/, "") }
        /^https?:\/\// { sub(/\/+$/, ""); print }
    ' "$list_file" | sort -u >"$WORK_DIR/mirrors.txt"
    [[ -s "$WORK_DIR/mirrors.txt" ]] || die "The mirror index did not contain usable HTTP(S) URLs"
}

human_speed() {
    local bytes_per_second="$1" bits_per_second
    bits_per_second=$((bytes_per_second * 8))
    if ((bits_per_second >= 1000000000)); then
        printf '%d.%01d Gb/s' "$((bits_per_second / 1000000000))" "$(((bits_per_second % 1000000000) / 100000000))"
    elif ((bits_per_second >= 1000000)); then
        printf '%d.%01d Mb/s' "$((bits_per_second / 1000000))" "$(((bits_per_second % 1000000) / 100000))"
    elif ((bits_per_second >= 1000)); then
        printf '%d.%01d Kb/s' "$((bits_per_second / 1000))" "$(((bits_per_second % 1000) / 100))"
    else
        printf '%d b/s' "$bits_per_second"
    fi
}

select_probe_file() {
    local mirror="$1" architecture packages_url target_bytes

    architecture=$(dpkg --print-architecture)
    packages_url="$mirror/dists/$CODENAME/main/binary-$architecture/Packages.gz"
    target_bytes=$((TEST_SIZE_KB * 1024))

    curl --fail --location --silent --show-error "$packages_url" |
        gzip -dc |
        awk -v target="$target_bytes" '
            function consider() {
                if (filename == "" || size !~ /^[0-9]+$/) return
                if (size >= target && (best_size == 0 || size < best_size)) {
                    best_size = size
                    best_file = filename
                }
                if (size > largest_size) {
                    largest_size = size
                    largest_file = filename
                }
            }
            /^Filename: / { filename = substr($0, 11) }
            /^Size: / { size = $2 }
            /^$/ { consider(); filename = ""; size = 0 }
            END {
                consider()
                if (best_file != "") print best_file "\t" best_size
                else if (largest_file != "") print largest_file "\t" largest_size
                else exit 1
            }
        '
}

find_probe_file() {
    local mirror selection
    while IFS= read -r mirror; do
        if selection=$(select_probe_file "$mirror"); then
            IFS=$'\t' read -r PROBE_FILE PROBE_SIZE <<<"$selection"
            return 0
        fi
    done <"$WORK_DIR/mirrors.txt"
    die "Could not select a package payload for benchmarking"
}

test_mirrors() {
    local samples="$WORK_DIR/samples.tsv" results="$WORK_DIR/results.tsv"
    local mirror speed sample_end max_time round minimum_samples
    find_probe_file
    sample_end=$((TEST_SIZE_KB * 1024 - 1))
    max_time=$((TEST_SIZE_KB / 1024 + 15))
    ((max_time > 120)) && max_time=120
    minimum_samples=$((TEST_RUNS / 2 + 1))
    : >"$samples"

    printf 'Testing up to %s KiB of %s (package size: %s KiB), %s rounds per mirror...\n' \
        "$TEST_SIZE_KB" "$PROBE_FILE" "$((PROBE_SIZE / 1024))" "$TEST_RUNS"
    ((PROBE_SIZE >= sample_end + 1)) || warn "The largest available package is smaller than the requested sample size"
    for ((round = 1; round <= TEST_RUNS; round++)); do
        printf 'Benchmark round %s/%s...\n' "$round" "$TEST_RUNS"
        while IFS= read -r mirror; do
            if speed=$(curl --fail --location --silent --show-error \
                --connect-timeout 3 --max-time "$max_time" --range "0-$sample_end" \
                --output /dev/null --write-out '%{speed_download}' \
                "$mirror/$PROBE_FILE" 2>/dev/null); then
                [[ "$speed" =~ ^[0-9]+([.][0-9]+)?$ ]] || continue
                speed="${speed%.*}"
                ((speed > 0)) || continue
                printf '%s\t%s\n' "$speed" "$mirror" >>"$samples"
            else
                printf '  unavailable (%s/%s): %s\n' "$round" "$TEST_RUNS" "$mirror" >&2
            fi
        done <"$WORK_DIR/mirrors.txt"
    done

    awk -F '\t' -v minimum="$minimum_samples" '
        {
            mirror = $2
            count[mirror]++
            values[mirror, count[mirror]] = $1 + 0
        }
        END {
            for (mirror in count) {
                n = count[mirror]
                if (n < minimum) continue
                for (i in sorted) delete sorted[i]
                for (i = 1; i <= n; i++) sorted[i] = values[mirror, i]
                for (i = 1; i <= n; i++) {
                    for (j = i + 1; j <= n; j++) {
                        if (sorted[j] < sorted[i]) {
                            temporary = sorted[i]
                            sorted[i] = sorted[j]
                            sorted[j] = temporary
                        }
                    }
                }
                if (n % 2 == 1) median = sorted[(n + 1) / 2]
                else median = int((sorted[n / 2] + sorted[n / 2 + 1]) / 2)
                print median "\t" mirror
            }
        }
    ' "$samples" >"$results"

    sort -rn -k1,1 "$results" >"$WORK_DIR/ranked.tsv"
    [[ -s "$WORK_DIR/ranked.tsv" ]] || die "No mirror supplied a usable package payload for $CODENAME"
}

show_rankings() {
    local index=0 speed mirror
    printf '\nFastest reachable mirrors (median of %s rounds):\n' "$TEST_RUNS"
    while IFS=$'\t' read -r speed mirror; do
        ((index += 1))
        printf '  %2d. %-11s %s\n' "$index" "$(human_speed "$speed")" "$mirror"
        ((index >= DEFAULT_TOP_LIMIT)) && break
    done <"$WORK_DIR/ranked.tsv"
}

choose_mirrors() {
    local -n output_ref="$1"
    local available requested index speed mirror
    mapfile -t lines <"$WORK_DIR/ranked.tsv"
    available=${#lines[@]}
    requested=$MIRROR_COUNT
    ((requested <= available)) || { warn "Only $available mirror(s) are available; using all of them"; requested=$available; }

    if "$AUTO_SELECT"; then
        for ((index = 0; index < requested; index++)); do
            IFS=$'\t' read -r speed mirror <<<"${lines[index]}"
            output_ref+=("$mirror")
        done
        return
    fi

    [[ -t 0 ]] || die "Interactive selection needs a terminal; use --auto"
    printf '\nChoose up to %d mirror(s), separated by spaces (0 cancels): ' "$requested"
    local -a selected_indexes=()
    read -r -a selected_indexes
    ((${#selected_indexes[@]} > 0)) || die "No mirror selected"
    ((${#selected_indexes[@]} <= requested)) || die "You selected more than $requested mirror(s)"
    for index in "${selected_indexes[@]}"; do
        [[ "$index" =~ ^[1-9][0-9]*$ ]] && ((index <= available)) || die "Invalid mirror number: $index"
        IFS=$'\t' read -r speed mirror <<<"${lines[index - 1]}"
        output_ref+=("$mirror")
    done
}

render_deb822() {
    local input="$1" output="$2" uri_list="$3"
    awk -v uris="$uri_list" '
        /^[[:space:]]*URIs:[[:space:]]*/ { print "URIs: " uris; changed=1; next }
        { print }
        END { if (!changed) exit 42 }
    ' "$input" >"$output" || die "No URIs: field found in $input"
}

render_legacy() {
    local input="$1" output="$2" replacement="$3"
    awk -v replacement="$replacement" '
        function ubuntu_archive(uri) {
            return uri ~ /^https?:\/\/([[:alnum:]-]+\.)*ubuntu\.com\/ubuntu\/?$/
        }
        {
            if ($1 == "deb" || $1 == "deb-src") {
                uri_field=2
                if ($2 ~ /^\[/) {
                    while (uri_field <= NF && $uri_field !~ /\]$/) uri_field++
                    uri_field++
                }
                if (ubuntu_archive($uri_field)) {
                    $uri_field=replacement
                    changed=1
                }
            }
            print
        }
        END { if (!changed) exit 42 }
    ' "$input" >"$output" || die "No official Ubuntu archive URI found in $input"
}

render_source_file() {
    local output="$1"; shift
    local uri_list="${*//$'\n'/ }"
    if [[ "$SOURCE_FORMAT" == "deb822" ]]; then
        render_deb822 "$SOURCE_FILE" "$output" "$uri_list"
    else
        ((${#@} == 1)) || warn "Legacy sources.list accepts one URI per entry; applying only the fastest mirror"
        render_legacy "$SOURCE_FILE" "$output" "$1"
    fi
}

show_plan() {
    local -a mirrors=("$@")
    printf '\nTarget: %s (%s)\n' "$SOURCE_FILE" "$SOURCE_FORMAT"
    printf 'Selected mirror(s):\n'
    printf '  - %s\n' "${mirrors[@]}"
}

apply_source_file() {
    local planned_file="$1" timestamp temp_file
    [[ $EUID -eq 0 ]] || die "Applying changes requires sudo/root; use --dry-run to preview"
    timestamp=$(date -u +%Y%m%dT%H%M%SZ)
    BACKUP_FILE="${SOURCE_FILE}.${PROGRAM_NAME}.${timestamp}.bak"
    cp -a -- "$SOURCE_FILE" "$BACKUP_FILE"
    printf 'Backup created: %s\n' "$BACKUP_FILE"

    temp_file=$(mktemp "${SOURCE_FILE}.tmp.XXXXXX")
    cp -a -- "$planned_file" "$temp_file"
    chmod --reference="$SOURCE_FILE" "$temp_file"
    chown --reference="$SOURCE_FILE" "$temp_file"
    mv -f -- "$temp_file" "$SOURCE_FILE"

    if "$SKIP_APT_UPDATE"; then
        warn "Skipped apt-get update by request; restore with: cp -a '$BACKUP_FILE' '$SOURCE_FILE'"
        return
    fi

    printf 'Verifying the new source with apt-get update...\n'
    if ! apt-get update; then
        warn "apt-get update failed; restoring $BACKUP_FILE"
        cp -a -- "$BACKUP_FILE" "$SOURCE_FILE"
        die "The previous APT source was restored"
    fi
    printf 'APT sources updated and verified.\n'
}

main() {
    parse_args "$@"
    require_commands
    detect_ubuntu
    detect_source_file
    WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/${PROGRAM_NAME}.XXXXXX")
    fetch_mirrors
    test_mirrors
    show_rankings

    local -a selected_mirrors=()
    choose_mirrors selected_mirrors
    show_plan "${selected_mirrors[@]}"

    local planned_file="$WORK_DIR/planned.sources"
    render_source_file "$planned_file" "${selected_mirrors[@]}"
    if "$DRY_RUN"; then
        printf '\nDry run: no system files will be changed.\n'
        diff -u --label "$SOURCE_FILE (current)" --label "$SOURCE_FILE (planned)" "$SOURCE_FILE" "$planned_file" || true
        return
    fi

    if ! "$AUTO_SELECT"; then
        local answer
        read -r -p 'Apply this change and create a backup? [y/N] ' answer
        [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]] || { printf 'Cancelled.\n'; return; }
    fi
    apply_source_file "$planned_file"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
