#!/bin/bash

#================================================================
# HEADER
#================================================================
#% SYNOPSIS
#%    ./run [-h|--help] [-c|--country <country-code> ...] [-s|--size <size-in-kb>]
#%          [-n|--number <count>] [-L|--legacy] [-a|--auto] [-b|--backup] 
#%
#% DESCRIPTION
#%   This script retrieves a list of Ubuntu mirrors based on specified country codes.
#%   If no country codes are provided, it defaults to using mirrors.txt, which contains
#%   geographic mirrors based on the client's source IP address. It then tests the speed
#%   of each mirror and displays the top fastest mirrors. It can replace the default mirrors
#%   with the fastest ones and includes backup capabilities. 
#%   By default, it selects one mirror, but you can specify the number of mirrors to use with the -n option.
#%   For Ubuntu 24.04+, it will update the "ubuntu.sources" file in "/etc/apt/sources.list.d/".
#%   For older Ubuntu versions, it will update the traditional "/etc/apt/sources.list" file.
#%   The script creates backups of the original files before making changes (if backup is enabled).
#%   You can check the current status of mirrors at https://launchpad.net/ubuntu/+archivemirrors 
#%   and find available country codes at http://mirrors.ubuntu.com/.
#%
#% OPTIONS
#%    -h, --help       Show this help message and exit.
#%    -c, --country    Specify one or more country codes to retrieve mirrors from. If not
#%                     provided, the script will default to using mirrors from
#%                     http://mirrors.ubuntu.com/mirrors.txt.
#%    -n, --number     Specify the number of fastest mirrors to apply. Default is 1.
#%    -a, --auto       Select fastest mirror(s) automatically without user
#%                     prompt and automatically create backups.
#%    -b, --backup     Backup apt sources files before making changes.
#%                     For Ubuntu 24.04+: creates backups of "ubuntu.sources" file in sources.list.d/
#%                     For older Ubuntu: creates backup of sources.list
#%    -s, --size       Specify the test size in KB (Kilobytes) for speed tests. Default is 100KB.
#%                     This is the size of the file downloaded from each mirror for testing.
#%    -L, --legacy     Force using the legacy method (sources.list) even if Ubuntu version is 24.04+
#%                     or if version detection fails. By default without this option, if Ubuntu version
#%                     can't be determined, the script will use the Ubuntu 24.04+ method.
#%
#% DATA UNITS USED
#%    KB = Kilobytes (1024 bytes) - Used for file sizes
#%    Kbps = Kilobits per second - Used for network speeds
#%    Mbps = Megabits per second
#%    Gbps = Gigabits per second
#%
#% EXAMPLES
#%    ./run -c US JP ID -n 3 -a  # Automatically select top 3 mirrors from US, JP, ID
#%    ./run -b -c ID -n 2       # Select 2 mirrors from Indonesia with backup
#%    ./run -a                  # Automatically select the single fastest mirror
#%    ./run -s 500
#%    ./run
#%
#% LICENSE
#%    Distributed under the MIT License.
#%
#================================================================
# END_OF_HEADER
#================================================================

# Constants
COUNTRY_CODE_INCLUDED=()
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
TOP_LIST_AMOUNT=10 # ИЗМЕНЕНО: Увеличим количество отображаемых зеркал для большего выбора
reset_color='\033[0m'
auto_select=false
top_mirrors=()
backup=false
test_size_in_kb=9000
force_legacy_mode=false
num_mirrors_to_select=1 # НОВОЕ: Количество зеркал для выбора, по умолчанию 1

# Function to clean up cache on exit
cleanup_cache() {
    rm -rf "$SCRIPT_DIR/.cache"
}

# Function to validate country code
validate_country_code() {
    local code="$1"
    if ! wget -q --spider "http://mirrors.ubuntu.com/$code.txt"; then
        echo "Error: Invalid country code '$code'" >&2
        return 1
    fi
    return 0
}

# Function to format color based on speed
format_color() {
    local speed_bps=$1
    speed_kbps=$(bc -l <<<"$speed_bps / 1000")

    if (($(bc <<<"$speed_kbps == 0"))); then
        echo "\e[38;5;9m"
    elif (($(bc <<<"$speed_kbps < 100"))); then
        echo "\e[38;5;88m"
    elif (($(bc <<<"$speed_kbps < 275"))); then
        echo "\e[38;5;58m"
    elif (($(bc <<<"$speed_kbps < 1000"))); then
        echo "\e[38;5;178m"
    elif (($(bc <<<"$speed_kbps < 2000"))); then
        echo "\e[38;5;34m"
    else
        echo "\e[38;5;46m"
    fi
}

# Function to convert speed to human-readable format
convert_speed() {
    local speed=$1
    if ((speed >= 1000000000)); then
        echo "$(bc -l <<<"scale=1; $speed / 1000000000") Gbps"  # Gigabits per second
    elif ((speed >= 1000000)); then
        echo "$(bc -l <<<"scale=1; $speed / 1000000") Mbps"     # Megabits per second
    elif ((speed >= 1000)); then
        echo "$(bc -l <<<"scale=1; $speed / 1000") Kbps"        # Kilobits per second
    else
        echo "${speed} bps"                                      # Bits per second
    fi
}

# Function to show help message
show_help() {
    awk '/^#%/{gsub(/^#% ?/,""); print}' "$0"
}

# Function to process command line arguments
process_arguments() {
    if [[ "$*" == *"-h"* || "$*" == *" --help"* ]]; then
        show_help
        exit 0
    fi

    while [[ "$1" != "" ]]; do
        case "$1" in
        -c | --country)
            shift
            while [[ "$1" != "" && ! "$1" =~ ^- ]]; do
                country_code=$(echo "$1" | tr '[:lower:]' '[:upper:]')
                COUNTRY_CODE_INCLUDED+=("$country_code")
                shift
            done
            continue 
            ;;
        -a | --auto-select)
            check_root
            auto_select=true
            backup=true
            ;;
        -b | --backup)
            check_root
            backup=true
            ;;
        # НОВОЕ: Обработка аргумента для количества зеркал
        -n | --number)
            shift
            if [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -gt 0 ]; then
                num_mirrors_to_select="$1"
            else
                echo "Error: Number of mirrors must be a positive integer."
                exit 1
            fi
            ;;
        -s | --size)
            shift
            if [[ "$1" =~ ^[0-9]+$ ]]; then
                test_size_in_kb="$1"
            else
                echo "Error: Size must be a positive integer in KB (Kilobytes)."
                exit 1
            fi
            ;;
        -L | --legacy)
            force_legacy_mode=true
            ;;
        -h | --help)
            show_help
            exit 0
            ;;
        *)
            echo "Error: Unknown option: $1"
            show_help
            exit 1
            ;;
        esac
        shift
    done
}

# Function to check Ubuntu version
check_ubuntu_version() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [[ "$NAME" == "Ubuntu"* ]]; then
            echo "$VERSION_ID"
            return 0
        else
            echo "Warning: This script is designed for Ubuntu, but detected $NAME $VERSION_ID" >&2
            return 1
        fi
    else
        echo "Warning: Cannot determine distribution version, /etc/os-release not found" >&2
        return 1
    fi
}

# Function to determine if Ubuntu version is 24.04 or newer
is_ubuntu_24_or_newer() {
    if [ "$force_legacy_mode" = true ]; then
        return 1 
    fi

    local version
    version=$(check_ubuntu_version)
    if [[ -n "$version" ]]; then
        if (( $(echo "$version >= 24.04" | bc -l) )); then
            return 0
        else
            return 1
        fi
    else
        return 0
    fi
}

# Function to display Ubuntu version information to the user
display_ubuntu_info() {
    local version
    version=$(check_ubuntu_version)
    
    echo -e "\n=== Ubuntu Version Information ==="
    
    if [[ -n "$version" ]]; then
        echo -e "Detected: Ubuntu $version"
    else
        echo -e "Unable to detect Ubuntu version."
    fi
    
    if [ "$force_legacy_mode" = true ]; then
        echo -e "Legacy mode forced with -L option."
        echo -e "This script will update sources using the legacy format."
        echo -e "Target file: /etc/apt/sources.list"
    elif is_ubuntu_24_or_newer; then
        echo -e "This script will update sources using the new .sources format for Ubuntu 24.04+."
        echo -e "Target file: ubuntu.sources in /etc/apt/sources.list.d/"
    else
        echo -e "This script will update sources using the legacy format for Ubuntu versions before 24.04."
        echo -e "Target file: /etc/apt/sources.list"
    fi
    echo -e "===================================\n"
}

# Function to fetch mirrors
fetch_mirrors() {
    mkdir -p "$SCRIPT_DIR/.cache" || {
        echo "Error: Failed to create cache directory."
        exit 1
    }
    for country_code in "${COUNTRY_CODE_INCLUDED[@]}"; do
        if ! wget -q -O- "http://mirrors.ubuntu.com/$country_code.txt" >>"$SCRIPT_DIR/.cache/mirrors.txt"; then
            echo "Error: Failed to fetch mirrors from http://mirrors.ubuntu.com/$country_code.txt"
            exit 1
        fi
    done
}

# Function to test mirror speed
test_mirror_speed() {
    local mirrors=("$@")
    declare -A speeds

    if [ -f "$SCRIPT_DIR/.cache/mirrors.txt" ]; then
        mapfile -t mirrors <"$SCRIPT_DIR/.cache/mirrors.txt" || {
            echo "Error: Failed to read mirror list from cache."
            exit 1
        }
        total_mirrors=${#mirrors[@]}

        if [ "$total_mirrors" -eq 0 ]; then
            echo "Error: No mirrors found in the mirror list."
            exit 1
        fi

        echo -e "\nTesting mirrors for speed on $test_size_in_kb KB of data..."
        
        local test_size_in_bytes=$((${test_size_in_kb:-100} * 1024))
        
        seq_num=0
        for mirror_url in "${mirrors[@]}"; do
            seq_num=$((seq_num + 1))
            raw_speed_bps=$(curl --max-time 2 -r 0-$test_size_in_bytes -s -w %{speed_download} -o /dev/null "$mirror_url/ls-lR.gz")
            speed=$(convert_speed "$raw_speed_bps")
            speeds["$mirror_url"]="$raw_speed_bps"
            echo -e "[$seq_num/$total_mirrors] $mirror_url --> $(format_color "$raw_speed_bps") $speed $speed_unit $reset_color"
        done

        # ИЗМЕНЕНО: Сортируем и выводим TOP_LIST_AMOUNT самых быстрых
        sorted_mirrors=$(for mirror in "${!speeds[@]}"; do echo "$mirror ${speeds[$mirror]}"; done | sort -rn -k2 | head -n "$TOP_LIST_AMOUNT" | nl)

        echo -e "\n\e[1mTop $TOP_LIST_AMOUNT fastest mirrors:\e[0m"
        while read -r line; do
            line_number=$(echo "$line" | awk '{print $1}')
            mirror=$(echo "$line" | awk '{print $2}')
            speed=$(echo "$line" | awk '{print $3}')
            echo -e "\e[2m$line_number\e[0m $mirror --> $(format_color "$speed") $(convert_speed "$speed") $reset_color"
            top_mirrors+=("$mirror")
        done <<<"$sorted_mirrors"

    else
        echo "Error: No mirrors found. Please provide at least one valid country code."
        exit 1
    fi
}

# Function to check country code and retrieve mirrors
check_country_code() {
    if [ "${#COUNTRY_CODE_INCLUDED[@]}" -eq 0 ]; then
        COUNTRY_CODE_INCLUDED=("mirrors")
        echo "No country code provided using -c or --country options"
        echo "Retrieving list from http://mirrors.ubuntu.com/mirrors.txt"
    else
        for country_code in "${COUNTRY_CODE_INCLUDED[@]}"; do
            if ! validate_country_code "$country_code"; then
                exit 1
            fi
        done
        echo "Using mirrors from:"
        for country_code in "${COUNTRY_CODE_INCLUDED[@]}"; do
            echo "http://mirrors.ubuntu.com/$country_code.txt"
        done
    fi
}

# Function to check if script is run as root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "This script requires root privileges. Please run it with sudo."
        exit 1
    fi
}

# Function to use sudo only if available (relavant when sudo is unavailable, like in docker)
run_sudo() {
    if command -v sudo >/dev/null 2S>&1; then
        sudo "$@"
    else
        "$@"
    fi
}

# ИЗМЕНЕНО: Функция принимает массив зеркал
update_sources_ubuntu24() {
    local -a mirrors_to_set=("${@}")
    local uris_string=""
    for mirror in "${mirrors_to_set[@]}"; do
        uris_string+="$mirror "
    done
    
    echo "Updating sources for Ubuntu 24.04 or newer (ubuntu.sources format)..."
    if [ -d "/etc/apt/sources.list.d" ]; then
        for sourcefile in /etc/apt/sources.list.d/ubuntu.sources; do
            if [ -f "$sourcefile" ]; then
                # Заменяем всю строку URIs: на новый список зеркал
                run_sudo sed -i "s|^URIs: .*|URIs: ${uris_string}|" "$sourcefile" || {
                    echo "Error: Failed to update $sourcefile"
                    exit 1
                }
                echo "Updated $sourcefile with mirrors: ${uris_string}"
            fi
        done
        
        if [ ! -f "/etc/apt/sources.list.d/ubuntu.sources" ]; then
            echo "Warning: ubuntu.sources file not found in /etc/apt/sources.list.d/"
            echo "No changes were made. Please check your Ubuntu version or use -L for legacy mode."
            exit 1
        fi
    else
        echo "Error: /etc/apt/sources.list.d directory not found, cannot update sources."
        exit 1
    fi
}

# ИЗМЕНЕНО: Функция полностью переписана для работы с несколькими зеркалами
update_sources_legacy() {
    local -a mirrors_to_set=("${@}")
    local sources_file="/etc/apt/sources.list"
    local codename

    echo "Updating sources for older Ubuntu versions (legacy sources.list)..."
    if [ ! -f "$sources_file" ]; then
        echo "Error: $sources_file file not found"
        exit 1
    fi
    
    codename=$(lsb_release -cs)
    if [ -z "$codename" ]; then
        echo "Error: Could not determine Ubuntu codename (e.g., 'jammy', 'focal')."
        exit 1
    fi

    echo "Commenting out existing official Ubuntu mirror entries in $sources_file..."
    # Комментируем строки, которые выглядят как официальные зеркала Ubuntu
    run_sudo sed -i -E 's/^(deb.*(ubuntu.com|canonical.com)\/ubuntu.*)/# \1/g' "$sources_file"

    echo "Adding new mirror entries..."
    # Добавляем новые записи для каждого выбранного зеркала
    for mirror in "${mirrors_to_set[@]}"; do
        {
            echo ""
            echo "# Mirror added by script: ${mirror}"
            echo "deb ${mirror} ${codename} main restricted universe multiverse"
            echo "# deb-src ${mirror} ${codename} main restricted universe multiverse"
            echo "deb ${mirror} ${codename}-updates main restricted universe multiverse"
            echo "# deb-src ${mirror} ${codename}-updates main restricted universe multiverse"
            echo "deb ${mirror} ${codename}-backports main restricted universe multiverse"
            echo "# deb-src ${mirror} ${codename}-backports main restricted universe multiverse"
            echo "deb ${mirror} ${codename}-security main restricted universe multiverse"
            echo "# deb-src ${mirror} ${codename}-security main restricted universe multiverse"
        } | run_sudo tee -a "$sources_file" > /dev/null
    done
    echo "Updated $sources_file with new mirrors."
}


# ИЗМЕНЕНО: Функция выбора нескольких зеркал
select_mirror() {
    local real_top_mirrors_count=${#top_mirrors[@]}
    local -a selected_mirrors=()

    if [ "$real_top_mirrors_count" -eq 0 ]; then
        echo "Error. No mirrors found."
        exit 1
    fi
    
    # Убедимся, что не пытаемся выбрать больше зеркал, чем доступно
    if [ "$num_mirrors_to_select" -gt "$real_top_mirrors_count" ]; then
        echo "Warning: Requested to select $num_mirrors_to_select mirrors, but only $real_top_mirrors_count are available."
        num_mirrors_to_select=$real_top_mirrors_count
        echo "Will select top $num_mirrors_to_select mirrors."
    fi

    if [ "$auto_select" = true ]; then
        # Автоматически выбираем N самых быстрых
        selected_mirrors=("${top_mirrors[@]:0:$num_mirrors_to_select}")
    else
        # Интерактивный выбор
        echo -e "\nSelect up to $num_mirrors_to_select mirrors from the list above."
        read -rp "Enter numbers separated by spaces (e.g., 1 3 5), or enter 0 to cancel: " -a selections
        
        if [[ " ${selections[@]} " =~ " 0 " ]] || [ ${#selections[@]} -eq 0 ]; then
            echo -e "Cancelled. No changes made.\nExiting..."
            exit 0
        fi

        if [ "${#selections[@]}" -gt "$num_mirrors_to_select" ]; then
            echo "Error: You selected ${#selections[@]} mirrors, but the limit is $num_mirrors_to_select."
            exit 1
        fi

        for choice in "${selections[@]}"; do
            if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -gt "$real_top_mirrors_count" ] || [ "$choice" -lt 1 ]; then
                echo "Error. Invalid selection: '$choice'. Please select numbers between 1 and $real_top_mirrors_count."
                exit 1
            fi
            selected_mirrors+=("${top_mirrors[$((choice - 1))]}")
        done
    fi

    if [ ${#selected_mirrors[@]} -eq 0 ]; then
        echo "No mirrors were selected. Exiting."
        exit 1
    fi

    # Create backup if requested
    if [ "$backup" = true ]; then
        time_postfix=$(date -u +"UTC%Y-%m-%dT%H_%M_%S")
        mkdir -p /etc/apt/sources.list.backup || {
            echo "Error: Failed to create backup directory."
            exit 1
        }

        if is_ubuntu_24_or_newer; then
            echo "Backing up ubuntu.sources file from /etc/apt/sources.list.d/..."
            if [ -f "/etc/apt/sources.list.d/ubuntu.sources" ]; then
                cp -rp "/etc/apt/sources.list.d/ubuntu.sources" "/etc/apt/sources.list.backup/ubuntu.sources.${time_postfix}.bak" || {
                    echo "Error: Failed to create ubuntu.sources backup."
                    exit 1
                }
                echo "Backed up /etc/apt/sources.list.d/ubuntu.sources to /etc/apt/sources.list.backup/ubuntu.sources.${time_postfix}.bak"
            else 
                echo "Warning: ubuntu.sources file not found in /etc/apt/sources.list.d/"
            fi
        else
            echo "Backing up traditional sources.list for Ubuntu versions before 24.04..."
            cp -rp /etc/apt/sources.list /etc/apt/sources.list.backup/sources.list."$time_postfix".bak || {
                echo "Error: Failed to create sources.list backup."
                exit 1
            }
            if [ -f "/etc/apt/sources.list.backup/sources.list.$time_postfix.bak" ]; then
                echo -e "Backup created in /etc/apt/sources.list.backup/sources.list.$time_postfix.bak\n"
            else
                echo "Backup failed."
                exit 1
            fi
        fi
    fi

    echo "Selected mirrors:"
    for mirror in "${selected_mirrors[@]}"; do
        echo "  - $mirror"
    done
    
    # Update sources based on Ubuntu version
    if is_ubuntu_24_or_newer; then
        update_sources_ubuntu24 "${selected_mirrors[@]}" || exit 1
    else
        update_sources_legacy "${selected_mirrors[@]}" || exit 1
    fi

    echo "Testing new mirrors with apt update..."
    run_sudo rm -rf /var/lib/apt/lists/* && run_sudo apt update || {
        echo "Error: Failed to update apt packages with the new mirror(s)."
        exit 1
    }
}

# Trap to cleanup cache on exit
trap cleanup_cache EXIT

# Main execution
display_ubuntu_info
process_arguments "$@"
check_country_code
fetch_mirrors
test_mirror_speed "${COUNTRY_CODE_INCLUDED[@]}"
select_mirror
