#!/bin/bash
set -Eeuo pipefail

################################################################################
# Ubuntu Server 26.04 ZFSBootMenu Installation Script v3.0.52
# - Monolithic rpool structure (single dataset for easy rollback)
# - Partition-based layout (not whole disk)
# - Sanoid for snapshot management
# - Manual datapool creation later
################################################################################

# CONFIGURATION VARIABLES - EDIT THESE
################################################################################
# NOTE: DISK is selected interactively at runtime
# NOTE: RPOOL_SIZE is computed at runtime from RPOOL_PERCENT
HOSTNAME="myserver"                    # System hostname
USERNAME="admin"                       # Primary user
USER_PASSWORD=""                       # Set interactively at runtime
TIMEZONE="Europe/Zurich"               # Timezone
LOCALE="en_GB.UTF-8"                   # System locale (British English: metric units, 24h time)

# Pool configuration
RPOOL_PERCENT=80                       # Percentage of remaining disk for rpool (1-99)
SWAP_SIZE=8192                         # Swap partition size in MiB (set interactively based on RAM)
EFI_SIZE=1024                          # EFI partition size in MiB (1024 MiB = 1 GiB)

# ZFS properties
COMPRESSION="lz4"                      # Compression algorithm

# ZFS pool tuning
ASHIFT=12            # Sector alignment: 12=4K sectors (SSD/NVMe), 9=512B (legacy HDD)
ZFS_ATIME="off"      # Disable access-time updates for performance
ZFS_RELATIME="on"    # Relative atime (updates only if older than 1 day)

# Keyboard layout (set interactively at runtime from live session or manual entry)
KEYBOARD_LAYOUT="us"               # Keyboard layout code (e.g., us, ch, de, fr)
KEYBOARD_VARIANT=""                # Keyboard variant (e.g., fr for ch-fr, empty for default)

# APT mirror (selected at runtime by speed test; fallback to official archive)
APT_MIRROR="https://archive.ubuntu.com/ubuntu"

# Optional datapool configuration (set to empty string to skip)
DATAPOOL_NAME="ssdupl"                 # Name of the datapool (leave empty to skip auto-creation)
DATAPOOL_MOUNTPOINT=""                 # Derived from DATAPOOL_NAME in validate_inputs(); initialised here so set -u never fires
DISK_DATAPOOL=""                        # Set only in single-disk mode; empty in separate-disks mode so set -u never fires
DISK_DATAPOOL_ID=""                    # Resolved after partition creation; empty when DATAPOOL_NAME=""
DATAPOOL_TOPOLOGY=""                   # Set by select_datapool_topology_and_disks()
DATAPOOL_DISK_IDS=()
DISK_SETUP_MODE=""                     # "single-disk" or "separate-disks"; set during interactive config

# Optional software (all prompted during postreboot, not initial)
# Containers & virtualization
INSTALL_DOCKER=""    # y/n — Docker Engine via official apt repo
INSTALL_PODMAN=""    # y/n — rootless Podman from the Ubuntu archive
INSTALL_VIRT=""      # y/n — KVM/libvirt headless virtualization
# System health & updates
INSTALL_HEALTH=""    # y/n — smartmontools, ZED mail alerts, monthly scrub timers
INSTALL_UNATTENDED="" # y/n — unattended-upgrades (security updates)
INSTALL_MTA=""       # y/n — msmtp as sendmail replacement (relay for all alert mail)
ADMIN_EMAIL=""       # destination for smartd/ZED/fail2ban/unattended-upgrades mail
SMTP_HOST=""         # msmtp relay host
SMTP_PORT="587"      # 587 = STARTTLS, 465 = implicit TLS
SMTP_USER=""         # SMTP login
SMTP_PASS=""         # SMTP password — only ever written to /etc/msmtprc (mode 600)
MAIL_FROM=""         # envelope/header sender
# Remote access & security
INSTALL_TAILSCALE="" # y/n — Tailscale mesh VPN
TAILSCALE_AUTHKEY="" # optional tskey-... for unattended `tailscale up`
HARDEN_SSH=""        # y/n — key-only SSH, no root login
HARDEN_SSH_FORCE=""  # y/n — disable password login even without an authorized_keys file
INSTALL_UFW=""       # y/n — host firewall (default deny incoming)
INSTALL_FAIL2BAN=""  # y/n — SSH brute-force protection
INSTALL_NUT=""       # y/n — UPS monitoring (Network UPS Tools)
INSTALL_COCKPIT=""   # y/n — Cockpit web administration on :9090
# Services
INSTALL_SAMBA=""     # y/n — SMB/CIFS file server
INSTALL_NFS=""       # y/n — NFS server (pairs with the ZFS sharenfs property)
INSTALL_NODEEXP=""   # y/n — prometheus-node-exporter on :9100
INSTALL_NETDATA=""   # y/n — netdata dashboard on :19999
INSTALL_TOOLBELT=""  # y/n — git, rsync, jq, tree, fzf, ripgrep, bat, unzip
POSTREBOOT_DONE="n"  # flipped to "y" in zbm-installer.conf when postreboot completes
DOCKER_DATA_ROOT=""  # set by create_software_datasets()
VIRT_STORAGE_DIR=""  # set by create_software_datasets()
APT_UPDATED=0        # guard so apt_refresh() only updates package lists once per run

################################################################################
# LOCALE SEARCH
################################################################################
# Searches /usr/share/i18n/SUPPORTED for locales matching a user-supplied term.
# Sets the global LOCALE variable. Press Enter with no search term to keep default.
select_locale() {
    local supported_file="/usr/share/i18n/SUPPORTED"
    if [[ ! -f "$supported_file" ]]; then
        echo "Note: $supported_file not found, keeping locale: $LOCALE"
        return
    fi

    echo "Locale search — current default: $LOCALE"
    echo "Type a search term (e.g. 'de', 'ch', 'en_US') or press Enter to keep default."

    while true; do
        echo ""
        local term
        read -rp "Search locale (Enter to accept [$LOCALE]): " term

        # Empty input = keep current LOCALE
        if [[ -z "$term" ]]; then
            echo "  Keeping locale: $LOCALE"
            return
        fi

        # Search: extract first field (locale name), filter by term (case-insensitive)
        local -a results
        mapfile -t results < <(grep -Fi "$term" "$supported_file" | awk '{print $1}' | grep -v '^#')

        if [[ ${#results[@]} -eq 0 ]]; then
            echo "  No locales found matching '$term'. Try again."
            continue
        fi

        # Show up to 30 results to avoid flooding the terminal
        local display_count=${#results[@]}
        local truncated=false
        if [[ $display_count -gt 30 ]]; then
            display_count=30
            truncated=true
        fi

        echo ""
        for (( i=0; i<display_count; i++ )); do
            printf "  [%2d] %s\n" "$((i+1))" "${results[$i]}"
        done
        if $truncated; then
            echo "  ... (${#results[@]} total — refine your search to see more)"
        fi

        echo ""
        local choice
        read -rp "Select number, or press Enter to search again: " choice

        if [[ -z "$choice" ]]; then
            continue
        fi

        if [[ "$choice" =~ ^[0-9]+$ ]] && \
           [[ "$choice" -ge 1 ]] && [[ "$choice" -le "$display_count" ]]; then
            LOCALE="${results[$((choice-1))]}"
            echo "  Locale set to: $LOCALE"
            return
        fi

        echo "  Invalid selection. Press Enter to search again."
    done
}

################################################################################
# INTERACTIVE CONFIGURATION
################################################################################
configure_interactively() {
    echo ""
    echo "======================================================================"
    echo "=== Interactive Configuration ==="
    echo "Press Enter to accept the default value shown in [brackets]."
    echo "======================================================================"
    echo ""

    local input

    # Hostname
    read -rp "Hostname [$HOSTNAME]: " input
    if [[ -n "$input" ]]; then
        HOSTNAME="$input"
    fi

    # Username
    read -rp "Username [$USERNAME]: " input
    if [[ -n "$input" ]]; then
        USERNAME="$input"
    fi

    # Password (prompted silently, confirmed)
    while true; do
        read -rsp "Password for $USERNAME: " USER_PASSWORD
        echo ""
        read -rsp "Confirm password: " pw_confirm
        echo ""
        if [[ "$USER_PASSWORD" == "$pw_confirm" ]]; then
            break
        fi
        echo "Passwords do not match. Please try again."
    done

    # Timezone
    read -rp "Timezone [$TIMEZONE]: " input
    if [[ -n "$input" ]]; then
        TIMEZONE="$input"
    fi

    # Swap size - auto-detect RAM and suggest an appropriate size
    local ram_gb
    ram_gb=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo)
    local suggested_swap_gib
    if [[ $ram_gb -le 2 ]]; then
        suggested_swap_gib=2
    elif [[ $ram_gb -le 8 ]]; then
        suggested_swap_gib=$ram_gb
    else
        suggested_swap_gib=8
    fi
    SWAP_SIZE=$(( suggested_swap_gib * 1024 ))
    while true; do
        read -rp "Swap size in GiB (detected RAM: ${ram_gb}GiB, suggested: ${suggested_swap_gib}GiB) [${suggested_swap_gib}]: " input
        if [[ -z "$input" ]]; then
            break
        elif [[ ! "$input" =~ ^[0-9]+$ ]] || [[ "$input" -lt 1 ]]; then
            # validate_inputs enforces >=512 MiB later; reject here so the user
            # can correct it instead of aborting after all remaining prompts
            echo "  Error: swap size must be a whole number of GiB, at least 1. Try again."
        else
            SWAP_SIZE=$(( input * 1024 ))
            break
        fi
    done

    # Locale (interactive search)
    echo ""
    select_locale

    # ZFS compression
    echo ""
    echo "ZFS compression options: lz4 (fast, good ratio) | zstd (better ratio, slower) | gzip (best ratio, slowest) | none"
    read -rp "ZFS compression (lz4/zstd/gzip/none) [$COMPRESSION]: " input
    if [[ -n "$input" ]]; then
        COMPRESSION="$input"
    fi

    # Keyboard layout: detect from live session, offer to reuse
    echo ""
    local live_layout="" live_variant=""
    if [[ -f /etc/default/keyboard ]]; then
        live_layout=$(grep '^XKBLAYOUT=' /etc/default/keyboard | cut -d= -f2 | tr -d '"' || true)
        live_variant=$(grep '^XKBVARIANT=' /etc/default/keyboard | cut -d= -f2 | tr -d '"' || true)
    fi
    if [[ -n "$live_layout" ]]; then
        local kbd_display="$live_layout"
        [[ -n "$live_variant" ]] && kbd_display="$live_layout/$live_variant"
        read -rp "Use live-session keyboard layout ($kbd_display)? [Y/n]: " input
        if [[ ! "$input" =~ ^[Nn]$ ]]; then
            KEYBOARD_LAYOUT="$live_layout"
            KEYBOARD_VARIANT="${live_variant:-}"
        else
            read -rp "Keyboard layout [$KEYBOARD_LAYOUT]: " input
            [[ -n "$input" ]] && KEYBOARD_LAYOUT="$input"
            read -rp "Keyboard variant (leave blank for none) [${KEYBOARD_VARIANT:-}]: " input
            KEYBOARD_VARIANT="$input"
        fi
    else
        echo "No keyboard layout detected from live session."
        read -rp "Keyboard layout [$KEYBOARD_LAYOUT]: " input
        [[ -n "$input" ]] && KEYBOARD_LAYOUT="$input"
        read -rp "Keyboard variant (leave blank for none) [${KEYBOARD_VARIANT:-}]: " input
        KEYBOARD_VARIANT="$input"
    fi

    # Datapool: ask yes/no first, then name if yes
    echo ""
    local datapool_yn
    if [[ -n "$DATAPOOL_NAME" ]]; then
        read -rp "Create a datapool? [Y/n]: " datapool_yn
        if [[ "$datapool_yn" =~ ^[Nn]$ ]]; then
            DATAPOOL_NAME=""
        else
            read -rp "  Datapool name [$DATAPOOL_NAME]: " input
            if [[ -n "$input" ]]; then
                DATAPOOL_NAME="$input"
            fi
        fi
    else
        read -rp "Create a datapool? [y/N]: " datapool_yn
        if [[ "$datapool_yn" =~ ^[Yy]$ ]]; then
            local default_dp="datapool"
            read -rp "  Datapool name [$default_dp]: " input
            DATAPOOL_NAME="${input:-$default_dp}"
        fi
    fi

    # Disk setup mode (only relevant when a datapool is configured)
    if [[ -n "$DATAPOOL_NAME" ]]; then
        echo ""
        echo "--- Disk setup ---"
        echo "  [1] single-disk  — rpool and datapool share the same disk"
        echo "                     (rpool = partition 3, datapool = partition 4)"
        echo "  [2] separate     — rpool on one dedicated disk; datapool on separate disk(s)"
        echo "                     (single whole disk / mirror / raidz)"
        local mode_choice
        while true; do
            read -rp "Select disk setup [1/2]: " mode_choice
            case "$mode_choice" in
                1) DISK_SETUP_MODE="single-disk";   break ;;
                2) DISK_SETUP_MODE="separate-disks"; break ;;
                *) echo "Invalid selection. Enter 1 or 2." ;;
            esac
        done
    else
        DISK_SETUP_MODE="single-disk"
    fi

    # Summary
    echo ""
    echo "======================================================================"
    echo "Configuration summary:"
    echo "  Hostname:     $HOSTNAME"
    echo "  Username:     $USERNAME"
    echo "  Password:     (set)"
    echo "  Timezone:     $TIMEZONE"
    echo "  Locale:       $LOCALE"
    echo "  Swap size:    $(( SWAP_SIZE / 1024 ))GiB"
    echo "  Compression:  $COMPRESSION"
    local kbd_summary="$KEYBOARD_LAYOUT"
    [[ -n "$KEYBOARD_VARIANT" ]] && kbd_summary="$KEYBOARD_LAYOUT/$KEYBOARD_VARIANT"
    echo "  Keyboard:     $kbd_summary"
    echo "  Datapool:     ${DATAPOOL_NAME:-<none>}"
    echo "  Disk setup:   ${DISK_SETUP_MODE}"
    echo "======================================================================"
    echo ""
}

################################################################################
# INPUT VALIDATION
################################################################################
validate_inputs() {
    # Validate USERNAME (alphanumeric, dash, underscore only)
    if [[ ! "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        echo "Error: Invalid USERNAME '$USERNAME'. Must start with lowercase letter or underscore,"
        echo "       and contain only lowercase letters, numbers, underscores, and dashes."
        exit 1
    fi

    # Validate HOSTNAME (RFC 1123 compliant)
    if [[ ! "$HOSTNAME" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
        echo "Error: Invalid HOSTNAME '$HOSTNAME'. Must be 1-63 characters,"
        echo "       start/end with alphanumeric, contain only lowercase letters, numbers, and dashes."
        exit 1
    fi

    # Validate TIMEZONE (check if file exists)
    if [[ ! -f "/usr/share/zoneinfo/$TIMEZONE" ]]; then
        echo "Error: Invalid TIMEZONE '$TIMEZONE'."
        echo "       File /usr/share/zoneinfo/$TIMEZONE does not exist."
        echo "       Example valid timezones: America/New_York, Europe/London, Asia/Tokyo"
        exit 1
    fi

    # Validate LOCALE format — accept everything select_locale can offer from
    # /usr/share/i18n/SUPPORTED: C/POSIX, 2-3 letter languages, optional
    # country, encoding and @modifier (e.g. C.UTF-8, ca_ES.UTF-8@valencia)
    if [[ ! "$LOCALE" =~ ^(C|POSIX)(\.[A-Za-z0-9-]+)?$ ]] \
       && [[ ! "$LOCALE" =~ ^[a-z]{2,3}(_[A-Z]{2})?(\.[A-Za-z0-9-]+)?(@[A-Za-z0-9]+)?$ ]]; then
        echo "Error: Invalid LOCALE '$LOCALE'."
        echo "       Format should be: language_COUNTRY.encoding (e.g., en_US.UTF-8)"
        exit 1
    fi

    # Validate EFI_SIZE (integer MiB, minimum 256 MiB)
    if [[ ! "$EFI_SIZE" =~ ^[0-9]+$ ]] || [[ "$EFI_SIZE" -lt 256 ]]; then
        echo "Error: Invalid EFI_SIZE '$EFI_SIZE'. Must be a positive integer in MiB (minimum 256)."
        exit 1
    fi

    # Validate SWAP_SIZE (integer MiB, minimum 512 MiB)
    if [[ ! "$SWAP_SIZE" =~ ^[0-9]+$ ]] || [[ "$SWAP_SIZE" -lt 512 ]]; then
        echo "Error: Invalid SWAP_SIZE '$SWAP_SIZE'. Must be a positive integer in MiB (minimum 512)."
        exit 1
    fi

    if [[ ! "$RPOOL_PERCENT" =~ ^[0-9]+$ ]] || \
       [[ "$RPOOL_PERCENT" -lt 1 ]] || [[ "$RPOOL_PERCENT" -gt 99 ]]; then
        echo "Error: Invalid RPOOL_PERCENT '$RPOOL_PERCENT'. Must be an integer between 1 and 99."
        exit 1
    fi

    # Validate DATAPOOL_NAME if set (alphanumeric, dash, underscore only, no spaces)
    if [[ -n "$DATAPOOL_NAME" ]]; then
        if [[ ! "$DATAPOOL_NAME" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
            echo "Error: Invalid DATAPOOL_NAME '$DATAPOOL_NAME'."
            echo "       Must start with a letter and contain only letters, numbers, underscores, and dashes."
            echo "       No spaces allowed."
            exit 1
        fi
    fi

    # Derive datapool mountpoint from pool name. Only when it is still unset —
    # postreboot sources zbm-installer.conf before calling this, and an imported
    # pool may legitimately have a mountpoint that is not /<poolname>.
    if [[ -n "$DATAPOOL_NAME" && -z "$DATAPOOL_MOUNTPOINT" ]]; then
        DATAPOOL_MOUNTPOINT="/$DATAPOOL_NAME"
    fi

    # Validate COMPRESSION
    if [[ ! "$COMPRESSION" =~ ^(lz4|zstd|gzip|none)$ ]]; then
        echo "Error: Invalid COMPRESSION '$COMPRESSION'. Must be one of: lz4, zstd, gzip, none"
        exit 1
    fi

    # Validate KEYBOARD_LAYOUT (lowercase letters only, 2-8 chars; e.g. us, de, ch, latam)
    if [[ ! "$KEYBOARD_LAYOUT" =~ ^[a-z]{2,8}$ ]]; then
        echo "Error: Invalid KEYBOARD_LAYOUT '$KEYBOARD_LAYOUT'."
        echo "       Must be 2-8 lowercase letters (e.g., us, de, ch, fr, latam)."
        exit 1
    fi

    # Validate KEYBOARD_VARIANT (empty, or lowercase start + letters/digits/underscore/dash)
    if [[ -n "$KEYBOARD_VARIANT" ]] && [[ ! "$KEYBOARD_VARIANT" =~ ^[a-z][a-z0-9_-]*$ ]]; then
        echo "Error: Invalid KEYBOARD_VARIANT '$KEYBOARD_VARIANT'."
        echo "       Must be empty or start with a lowercase letter followed by letters, digits, underscores, or dashes."
        exit 1
    fi
}

validate_disk_size() {
    local disk=$1

    local disk_bytes
    disk_bytes=$(blockdev --getsize64 "$disk")
    local disk_mib=$(( disk_bytes / 1024 / 1024 ))

    # Minimum required: EFI + Swap + 2 GiB alignment buffer
    local required_mib=$(( EFI_SIZE + SWAP_SIZE + 2048 ))

    echo "Disk size: $(( disk_mib / 1024 ))GiB"
    echo "Required:  $(( required_mib / 1024 ))GiB  (EFI: $(( EFI_SIZE / 1024 ))GiB, Swap: $(( SWAP_SIZE / 1024 ))GiB, buffer: 2GiB)"

    if [[ $disk_mib -lt $required_mib ]]; then
        echo "Error: Disk is too small!"
        echo "       Disk: $(( disk_mib / 1024 ))GiB,  Required: $(( required_mib / 1024 ))GiB minimum"
        exit 1
    fi

    echo "Disk size validation passed."
}

################################################################################
# INTERACTIVE DISK AND SIZE SELECTION
################################################################################

# Resolve a partition block device to its most stable available path.
# Priority: /dev/disk/by-id/ (ata-/nvme-, skips wwn-)
#        -> /dev/disk/by-partuuid/ (works on VMs with virtio disks)
#        -> raw device path (last resort)
resolve_part_byid() {
    local part
    part=$(readlink -f "$1")

    # Prefer by-id (physical disks: ata-, nvme-)
    local byid
    byid=$(find /dev/disk/by-id/ -maxdepth 1 -type l 2>/dev/null \
        | while read -r link; do
            [[ "$(readlink -f "$link")" == "$part" ]] && echo "$link"
          done \
        | grep -v "/wwn-" | sort | head -1) || true
    if [[ -n "$byid" ]]; then
        echo "$byid"
        return
    fi

    # by-partuuid — stable for partitions on VMs (virtio, paravirtual); preferred over by-path for partitions
    local bypartuuid
    bypartuuid=$(find /dev/disk/by-partuuid/ -maxdepth 1 -type l 2>/dev/null \
        | while read -r link; do
            [[ "$(readlink -f "$link")" == "$part" ]] && echo "$link"
          done | head -1) || true
    if [[ -n "$bypartuuid" ]]; then
        echo "$bypartuuid"
        return
    fi

    # by-path — stable for whole disks on VMs where by-id has no serial
    # grep -v "part" keeps only whole-disk links (not partition sub-links)
    local bypath
    bypath=$(find /dev/disk/by-path/ -maxdepth 1 -type l 2>/dev/null \
        | while read -r link; do
            [[ "$(readlink -f "$link")" == "$part" ]] && echo "$link"
          done | grep -v "part" | sort | head -1) || true
    if [[ -n "$bypath" ]]; then
        echo "$bypath"
        return
    fi

    # Last resort: raw device path
    echo "$1"
}

# Present a numbered list of block devices and let the user choose one.
# Sets the global DISK variable (e.g., /dev/sda).
select_disk() {
    echo ""
    echo "======================================================================"
    if [[ "$DISK_SETUP_MODE" == "separate-disks" ]]; then
        echo "Select the system disk (EFI, Swap, and rpool only — datapool on a separate disk):"
    elif [[ -n "$DATAPOOL_NAME" ]]; then
        echo "Select the installation disk (rpool + datapool will share this disk):"
    else
        echo "Select the installation disk (EFI, Swap, and rpool):"
    fi
    echo "======================================================================"

    # Collect non-loop, non-optical block devices
    local -a names sizes models
    local i=0
    while IFS= read -r line; do
        local name size model byid
        name=$(echo "$line" | awk '{print $1}')
        size=$(echo "$line" | awk '{print $2}')
        model=$(echo "$line" | awk '{$1=$2=""; print $0}' | sed 's/^ *//')
        byid=$(find /dev/disk/by-id/ -maxdepth 1 -type l 2>/dev/null \
            | while read -r link; do
                [[ "$(readlink -f "$link")" == "/dev/$name" ]] && echo "$link"
              done \
            | grep -v "/wwn-" | sort | head -1) || true
        byid="${byid##*/}"
        names+=("$name")
        sizes+=("$size")
        models+=("$model")
        printf "  [%d] /dev/%-10s  %-8s  %-28s  %s\n" \
            "$((i + 1))" "$name" "$size" "$model" "${byid:--}"
        i=$(( i + 1 ))
    done < <(lsblk -d -o NAME,SIZE,MODEL --noheadings | grep -v '^loop\|^sr')

    if [[ ${#names[@]} -eq 0 ]]; then
        echo "Error: No suitable block devices found."
        exit 1
    fi

    echo ""
    local choice
    while true; do
        read -rp "Select disk number [1-${#names[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && \
           [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#names[@]} ]]; then
            break
        fi
        echo "Invalid selection. Please enter a number between 1 and ${#names[@]}."
    done

    DISK="/dev/${names[$((choice - 1))]}"
    echo "Selected disk: $DISK (${sizes[$((choice - 1))]})"
}

# Interactively select datapool topology and (for multi-disk) the member disks.
# Reads: DISK (install disk to exclude)
# Sets: DATAPOOL_TOPOLOGY  (single / mirror / raidz1 / raidz2 / raidz3)
#       DATAPOOL_DISK_IDS  (array of by-id/by-partuuid paths; empty for single)
select_datapool_topology_and_disks() {
    # Collect whole block devices that are NOT the install disk
    local -a extra_names extra_sizes extra_models
    while IFS= read -r line; do
        local name size model
        name=$(awk '{print $1}' <<< "$line")
        size=$(awk '{print $2}' <<< "$line")
        model=$(awk '{$1=$2=""; print $0}' <<< "$line" | sed 's/^ *//')
        [[ "/dev/$name" == "$DISK" ]] && continue
        extra_names+=("$name")
        extra_sizes+=("$size")
        extra_models+=("$model")
    done < <(lsblk -d -o NAME,SIZE,MODEL --noheadings | grep -v '^loop\|^sr')

    local n_extra=${#extra_names[@]}

    # In separate-disks mode every topology (including "single") needs at least
    # one extra whole disk — without this guard the selection loop below would
    # prompt "Select disk number [1-0]" forever
    if [[ "$DISK_SETUP_MODE" == "separate-disks" && $n_extra -lt 1 ]]; then
        echo ""
        echo "Warning: no extra disks found for the datapool (install disk $DISK is excluded)."
        return 1
    fi

    # Build list of valid topologies based on available disk count
    local -a topo_labels topo_values
    if [[ "$DISK_SETUP_MODE" == "separate-disks" ]]; then
        topo_labels+=("single  – 1 whole disk")
    else
        topo_labels+=("single  – partition 4 of install disk (no extra disks needed)")
    fi
    topo_values+=("single")
    if [[ $n_extra -ge 2 ]]; then
        topo_labels+=("mirror  – 2 whole disks (mirrored redundancy)")
        topo_values+=("mirror")
        topo_labels+=("raidz1  – 2+ whole disks (single-parity)")
        topo_values+=("raidz1")
    fi
    if [[ $n_extra -ge 3 ]]; then
        topo_labels+=("raidz2  – 3+ whole disks (double-parity)")
        topo_values+=("raidz2")
    fi
    if [[ $n_extra -ge 4 ]]; then
        topo_labels+=("raidz3  – 4+ whole disks (triple-parity)")
        topo_values+=("raidz3")
    fi

    echo ""
    echo "======================================================================"
    printf "Datapool topology (%d extra disk(s) found):\n" "$n_extra"
    echo "======================================================================"
    local i
    for i in "${!topo_labels[@]}"; do
        printf "  [%d] %s\n" "$((i+1))" "${topo_labels[$i]}"
    done
    echo ""

    local topo_choice
    while true; do
        read -rp "Select topology [1-${#topo_labels[@]}]: " topo_choice
        if [[ "$topo_choice" =~ ^[0-9]+$ ]] && \
           [[ "$topo_choice" -ge 1 ]] && [[ "$topo_choice" -le ${#topo_labels[@]} ]]; then
            break
        fi
        echo "Invalid selection."
    done

    DATAPOOL_TOPOLOGY="${topo_values[$((topo_choice-1))]}"
    DATAPOOL_DISK_IDS=()

    # In single-disk mode, "single" uses partition 4 of the install disk — no disk selection needed.
    # In separate-disks mode, "single" means 1 whole disk and still requires a selection below.
    [[ "$DATAPOOL_TOPOLOGY" == "single" && "$DISK_SETUP_MODE" == "single-disk" ]] && return

    # Determine minimum disk count for the chosen topology
    local min_disks
    case "$DATAPOOL_TOPOLOGY" in
        single)        min_disks=1 ;;
        mirror|raidz1) min_disks=2 ;;
        raidz2)        min_disks=3 ;;
        raidz3)        min_disks=4 ;;
    esac

    echo ""
    if [[ "$DATAPOOL_TOPOLOGY" == "single" ]]; then
        echo "Select the disk for the datapool (1 whole disk)."
    else
        echo "Select at least $min_disks disk(s) for the $DATAPOOL_TOPOLOGY pool."
    fi
    echo "(Install disk $DISK is excluded.)"

    local -a selected_devs
    local count=0
    local -a avail_indices
    for i in "${!extra_names[@]}"; do avail_indices+=("$i"); done

    while true; do
        echo ""
        echo "Available extra disks:"
        local -a menu_map=()
        local j=1
        for i in "${avail_indices[@]}"; do
            printf "  [%d] /dev/%-10s  %-8s  %s\n" \
                "$j" "${extra_names[$i]}" "${extra_sizes[$i]}" "${extra_models[$i]}"
            menu_map+=("$i")
            j=$((j+1))
        done
        echo ""

        if [[ $count -ge $min_disks ]]; then
            # "single" topology in separate-disks mode: exactly 1 disk, never ask for more
            [[ "$DATAPOOL_TOPOLOGY" == "single" ]] && break
            local more
            read -rp "Add another disk? [y/N]: " more
            [[ ! "$more" =~ ^[Yy]$ ]] && break
        fi

        local n_avail=${#avail_indices[@]}
        local choice
        while true; do
            read -rp "Select disk number [1-${n_avail}]: " choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && \
               [[ "$choice" -ge 1 ]] && [[ "$choice" -le $n_avail ]]; then
                break
            else
                echo "Invalid selection."
            fi
        done

        local orig_idx="${menu_map[$((choice-1))]}"
        local chosen_dev="/dev/${extra_names[$orig_idx]}"
        selected_devs+=("$chosen_dev")
        DATAPOOL_DISK_IDS+=("$(resolve_part_byid "$chosen_dev")")
        count=$((count+1))
        echo "  + Added: $chosen_dev (${extra_sizes[$orig_idx]})"

        # Remove selected disk from the available list
        local -a new_avail=()
        for i in "${avail_indices[@]}"; do
            [[ "$i" -ne "$orig_idx" ]] && new_avail+=("$i")
        done
        avail_indices=("${new_avail[@]}")
    done

    echo ""
    echo "Selected $DATAPOOL_TOPOLOGY disks: ${selected_devs[*]}"
}

# Refuse to silently destroy an existing ZFS pool. `zpool create -f` overwrites
# any label it finds, so every create path must ask first.
# Usage: confirm_labelclear <device-path>...
confirm_labelclear() {
    local dev _clear_it
    for dev in "$@"; do
        if zpool import -d "$dev" 2>/dev/null | grep -q "pool:"; then
            read -rp "  Disk $dev has an existing ZFS label. Clear it? [y/N]: " _clear_it
            if [[ "$_clear_it" =~ ^[Yy]$ ]]; then
                zpool labelclear -f "$dev"
            else
                echo "Error: Cannot create pool — existing label on $dev. Run: zpool labelclear -f $dev"
                exit 1
            fi
        fi
    done
}

# Offer to import an already existing (exported) ZFS pool as the datapool
# instead of creating a new one. Scans `zpool import` for candidates (rpool
# excluded).
# Sets on import: DATAPOOL_NAME, DATAPOOL_MOUNTPOINT (from the imported pool)
# Returns 0 when a pool was imported; 1 when none exist or the user declined.
offer_datapool_import() {
    local -a import_pools=()
    local name
    while IFS= read -r name; do
        [[ "$name" == "rpool" ]] && continue
        import_pools+=("$name")
    done < <(zpool import 2>/dev/null | awk '$1 == "pool:" {print $2}')

    (( ${#import_pools[@]} == 0 )) && return 1

    echo ""
    echo "Importable ZFS pool(s) found:"
    local i
    for i in "${!import_pools[@]}"; do
        printf "  [%d] %s\n" "$((i+1))" "${import_pools[$i]}"
    done
    local n_opts=$(( ${#import_pools[@]} + 1 ))
    printf "  [%d] none — create a new datapool instead\n" "$n_opts"
    echo ""

    local choice
    while true; do
        read -rp "Import an existing pool as the datapool? [1-$n_opts]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= n_opts )); then
            break
        fi
        echo "Invalid selection."
    done
    (( choice == n_opts )) && return 1

    local pool="${import_pools[$((choice-1))]}"
    echo "  - Importing pool '$pool'..."
    if ! zpool import "$pool" 2>/dev/null; then
        # Plain import fails when the pool was last used on another system
        # (hostid mismatch) — that needs -f
        read -rp "  Plain import failed (pool last used on another system?). Force import? [y/N]: " _force
        if [[ "$_force" =~ ^[Yy]$ ]]; then
            if ! zpool import -f "$pool"; then
                echo "Error: Could not import pool '$pool'."
                exit 1
            fi
        else
            echo "  Skipping import of '$pool'."
            return 1
        fi
    fi

    DATAPOOL_NAME="$pool"
    local mp
    mp=$(zfs get -H -o value mountpoint "$pool")
    if [[ "$mp" == /* ]]; then
        DATAPOOL_MOUNTPOINT="$mp"
    else
        # Pool root has no usable mountpoint (none/legacy) — give it one
        DATAPOOL_MOUNTPOINT="/$pool"
        zfs set mountpoint="$DATAPOOL_MOUNTPOINT" "$pool"
    fi
    echo "  ✓ Pool '$pool' imported, mounted at $DATAPOOL_MOUNTPOINT"
    return 0
}

# Show a breakdown of available space and prompt for rpool percentage.
# Reads: DISK, EFI_SIZE, SWAP_SIZE (MiB), RPOOL_PERCENT (default)
# Sets: RPOOL_SIZE in MiB
select_rpool_percent() {
    local disk=$1

    local disk_bytes
    disk_bytes=$(blockdev --getsize64 "$disk")
    local disk_mib=$(( disk_bytes / 1024 / 1024 ))

    # Remaining space after EFI, swap, and 2 GiB alignment buffer
    local remaining_mib=$(( disk_mib - EFI_SIZE - SWAP_SIZE - 2048 ))

    # Default rpool size from RPOOL_PERCENT
    local default_rpool_mib=$(( remaining_mib * RPOOL_PERCENT / 100 ))

    echo ""
    echo "======================================================================"
    echo "Disk space breakdown for $disk:"
    printf "  Total disk:          %dGiB\n" "$(( disk_mib / 1024 ))"
    printf "  EFI partition:     - %dGiB\n" "$(( EFI_SIZE / 1024 ))"
    printf "  Swap partition:    - %dGiB\n" "$(( SWAP_SIZE / 1024 ))"
    printf "  Alignment buffer:  - 2GiB\n"
    printf "  Available for rpool: %dGiB\n" "$(( remaining_mib / 1024 ))"
    echo "======================================================================"
    printf "Default rpool size: %d%% = %dGiB\n" "$RPOOL_PERCENT" "$(( default_rpool_mib / 1024 ))"
    echo ""

    local pct
    while true; do
        read -rp "Enter rpool percentage (1-99) [default: ${RPOOL_PERCENT}]: " pct
        # Use default if empty
        if [[ -z "$pct" ]]; then
            pct=$RPOOL_PERCENT
        fi
        # Validate integer 1-99
        if [[ ! "$pct" =~ ^[0-9]+$ ]] || \
           [[ "$pct" -lt 1 ]] || [[ "$pct" -gt 99 ]]; then
            echo "Invalid input. Please enter an integer between 1 and 99."
            continue
        fi

        local rpool_mib=$(( remaining_mib * pct / 100 ))

        # Soft warning if result is less than 10 GiB
        if [[ $rpool_mib -lt 10240 ]]; then
            echo "Warning: ${pct}% of available space is only $(( rpool_mib / 1024 ))GiB."
            echo "This may be too small for a functional system (recommended: at least 10GiB)."
            local yn
            read -rp "Continue anyway? [y/N]: " yn
            if [[ ! "$yn" =~ ^[Yy]$ ]]; then
                continue
            fi
        fi

        RPOOL_SIZE=$rpool_mib
        echo "rpool size set to: $(( RPOOL_SIZE / 1024 ))GiB"
        break
    done
}

# Display a full confirmation table of partition layout and system config.
# Requires DISK, EFI_SIZE, SWAP_SIZE, RPOOL_SIZE to be set.
# Exits cleanly (exit 0) if the user does not confirm.
show_disk_confirmation() {
    local disk=$1

    local disk_bytes
    disk_bytes=$(blockdev --getsize64 "$disk")
    local disk_mib=$(( disk_bytes / 1024 / 1024 ))

    local datapool_label="${DATAPOOL_NAME:-<none>}"

    echo ""
    echo "======================================================================"
    echo "INSTALLATION SUMMARY"
    echo "======================================================================"
    echo ""
    printf "Target disk:  %s  (%dGiB total)\n" "$disk" "$(( disk_mib / 1024 ))"
    echo ""
    echo "Partition layout:"
    printf "  Partition 1 (EFI):      %dGiB\n"  "$(( EFI_SIZE / 1024 ))"
    printf "  Partition 2 (Swap):     %dGiB\n"  "$(( SWAP_SIZE / 1024 ))"
    if [[ "$DISK_SETUP_MODE" == "separate-disks" ]]; then
        printf "  Partition 3 (rpool):    ~%dGiB (all remaining)\n" "$(( RPOOL_SIZE / 1024 ))"
        printf "  Datapool:               separate disk(s) — topology selected at postreboot\n"
    elif [[ -z "$DATAPOOL_NAME" ]]; then
        printf "  Partition 3 (rpool):    ~%dGiB (all remaining)\n" "$(( RPOOL_SIZE / 1024 ))"
    else
        local datapool_mib=$(( disk_mib - EFI_SIZE - SWAP_SIZE - RPOOL_SIZE - 2048 ))
        if [[ $datapool_mib -lt 0 ]]; then datapool_mib=0; fi
        printf "  Partition 3 (rpool):    %dGiB\n"     "$(( RPOOL_SIZE / 1024 ))"
        printf "  Partition 4 (datapool): ~%dGiB (remaining)\n" "$(( datapool_mib / 1024 ))"
    fi
    echo ""
    echo "System configuration:"
    echo "  Hostname:     $HOSTNAME"
    echo "  Username:     $USERNAME"
    echo "  Timezone:     $TIMEZONE"
    echo "  Locale:       $LOCALE"
    echo "  Compression:  $COMPRESSION"
    echo "  Datapool:     $datapool_label"
    echo ""
    echo "======================================================================"
    echo "WARNING: ALL DATA ON $disk WILL BE PERMANENTLY DESTROYED!"
    echo "======================================================================"
    echo ""
    local confirm
    read -rp "Type 'YES' to confirm and begin installation: " confirm
    if [[ "$confirm" != "YES" ]]; then
        echo "Installation cancelled."
        exit 0
    fi
}

################################################################################
# MIRROR SPEED SELECTION
################################################################################
# Fetches the GeoIP-filtered mirror list from mirrors.ubuntu.com (HTTP only —
# HTTPS port 443 is unreachable on that host), then measures actual throughput
# by downloading the first 100KB of ls-lR.gz from each candidate (technique
# from Baeldung "Selecting the Fastest Mirror via Command Line in Ubuntu").
# Falls back to a hardcoded list if the dynamic fetch returns fewer than 2
# usable mirrors. Uses awk for float comparison (no bc dependency).
select_fastest_mirror() {
    # ls-lR.gz lives at the mirror root; -r 0-102400 caps download at ~100KB
    # so each test completes in ≤2s regardless of file size
    local test_file="ls-lR.gz"
    local curl_timeout=2
    local fallback="https://archive.ubuntu.com/ubuntu"

    # Hardcoded fallback candidates (used when GeoIP list is unavailable)
    local -a builtin_candidates=(
        "https://archive.ubuntu.com/ubuntu"
        "https://mirror.init7.net/ubuntu"
        "https://ubuntu.mirror.liteserver.nl/ubuntu"
        "https://ftp.halifax.rwth-aachen.de/ubuntu"
        "https://mirror.de.leaseweb.net/ubuntu"
        "https://mirrors.edge.kernel.org/ubuntu"
    )

    echo ""
    echo "Fetching regional Ubuntu mirror list..."

    local -a candidates=()

    local raw_list
    # Use HTTP (not HTTPS) — mirrors.ubuntu.com port 443 times out;
    # port 80 returns the GeoIP-filtered list correctly
    if raw_list=$(curl -s --max-time 10 "http://mirrors.ubuntu.com/mirrors.txt" 2>/dev/null) \
        && [[ -n "$raw_list" ]]; then
        mapfile -t candidates < <(
            printf '%s\n' "$raw_list" \
            | awk '/^https?:\/\// { gsub(/\/$/, ""); print $1 }' \
            | awk '!seen[$0]++' \
            | head -n 8
        )
        echo "  Retrieved ${#candidates[@]} regional mirrors"
    else
        echo "  Could not fetch mirror list, using built-in candidates."
    fi

    # Fall back to hardcoded list when GeoIP returned nothing useful
    if (( ${#candidates[@]} < 2 )); then
        candidates=("${builtin_candidates[@]}")
        echo "  Using built-in candidate list."
    fi

    echo "  Testing ${#candidates[@]} mirrors (100KB sample each)..."

    local best_mirror=""
    local best_speed="0"

    for mirror in "${candidates[@]}"; do
        local speed
        speed=$(curl -s --max-time "$curl_timeout" -r 0-102400 -o /dev/null \
            -w "%{speed_download}" \
            "${mirror}/${test_file}" 2>/dev/null) || speed="0"
        [[ -z "$speed" ]] && speed="0"

        local speed_kb
        speed_kb=$(awk -v s="$speed" 'BEGIN { printf "%.0f", s/1024 }')
        printf "  %-55s %s KB/s\n" "$mirror" "$speed_kb"

        if awk -v s="$speed" -v b="$best_speed" 'BEGIN { exit !(s > b) }'; then
            best_speed="$speed"
            best_mirror="$mirror"
        fi
    done

    if [[ -n "$best_mirror" ]] && awk -v b="$best_speed" 'BEGIN { exit !(b > 0) }'; then
        APT_MIRROR="$best_mirror"
        local best_kb
        best_kb=$(awk -v s="$best_speed" 'BEGIN { printf "%.0f", s/1024 }')
        echo "  ✓ Selected mirror: $APT_MIRROR (${best_kb} KB/s)"
    else
        APT_MIRROR="$fallback"
        echo "  ✓ All mirror tests failed, using fallback: $APT_MIRROR"
    fi
}

################################################################################
# USER SHELL ENVIRONMENT (zellij config, bash aliases)
################################################################################
# Writes the Zellij config (Alt-based keybinds and plugin commands, mirrored
# from the admin box) to the given path. Deployed to /etc/skel before user
# creation so useradd -m copies it with correct ownership.
# Usage: write_zellij_config <target_file>
write_zellij_config() {
    cat > "$1" << 'ZELLIJ_KDL_EOF'
keybinds clear-defaults=true {
    locked {
        bind "Alt g" { SwitchToMode "normal"; }
    }
    pane {
        bind "left" { MoveFocus "left"; }
        bind "down" { MoveFocus "down"; }
        bind "up" { MoveFocus "up"; }
        bind "right" { MoveFocus "right"; }
        bind "c" { SwitchToMode "renamepane"; PaneNameInput 0; }
        bind "d" { NewPane "down"; SwitchToMode "normal"; }
        bind "e" { TogglePaneEmbedOrFloating; SwitchToMode "normal"; }
        bind "f" { ToggleFocusFullscreen; SwitchToMode "normal"; }
        bind "h" { MoveFocus "left"; }
        bind "i" { TogglePanePinned; SwitchToMode "normal"; }
        bind "j" { MoveFocus "down"; }
        bind "k" { MoveFocus "up"; }
        bind "l" { MoveFocus "right"; }
        bind "n" { NewPane; SwitchToMode "normal"; }
        bind "p" { SwitchFocus; }
        bind "Alt p" { SwitchToMode "normal"; }
        bind "r" { NewPane "right"; SwitchToMode "normal"; }
        bind "s" { NewPane "stacked"; SwitchToMode "normal"; }
        bind "w" { ToggleFloatingPanes; SwitchToMode "normal"; }
        bind "z" { TogglePaneFrames; SwitchToMode "normal"; }
    }
    tab {
        bind "left" { GoToPreviousTab; }
        bind "down" { GoToNextTab; }
        bind "up" { GoToPreviousTab; }
        bind "right" { GoToNextTab; }
        bind "1" { GoToTab 1; SwitchToMode "normal"; }
        bind "2" { GoToTab 2; SwitchToMode "normal"; }
        bind "3" { GoToTab 3; SwitchToMode "normal"; }
        bind "4" { GoToTab 4; SwitchToMode "normal"; }
        bind "5" { GoToTab 5; SwitchToMode "normal"; }
        bind "6" { GoToTab 6; SwitchToMode "normal"; }
        bind "7" { GoToTab 7; SwitchToMode "normal"; }
        bind "8" { GoToTab 8; SwitchToMode "normal"; }
        bind "9" { GoToTab 9; SwitchToMode "normal"; }
        bind "[" { BreakPaneLeft; SwitchToMode "normal"; }
        bind "]" { BreakPaneRight; SwitchToMode "normal"; }
        bind "b" { BreakPane; SwitchToMode "normal"; }
        bind "h" { GoToPreviousTab; }
        bind "j" { GoToNextTab; }
        bind "k" { GoToPreviousTab; }
        bind "l" { GoToNextTab; }
        bind "n" { NewTab; SwitchToMode "normal"; }
        bind "r" { SwitchToMode "renametab"; TabNameInput 0; }
        bind "s" { ToggleActiveSyncTab; SwitchToMode "normal"; }
        bind "Alt t" { SwitchToMode "normal"; }
        bind "x" { CloseTab; SwitchToMode "normal"; }
        bind "tab" { ToggleTab; }
    }
    resize {
        bind "left" { Resize "Increase left"; }
        bind "down" { Resize "Increase down"; }
        bind "up" { Resize "Increase up"; }
        bind "right" { Resize "Increase right"; }
        bind "+" { Resize "Increase"; }
        bind "-" { Resize "Decrease"; }
        bind "=" { Resize "Increase"; }
        bind "H" { Resize "Decrease left"; }
        bind "J" { Resize "Decrease down"; }
        bind "K" { Resize "Decrease up"; }
        bind "L" { Resize "Decrease right"; }
        bind "h" { Resize "Increase left"; }
        bind "j" { Resize "Increase down"; }
        bind "k" { Resize "Increase up"; }
        bind "l" { Resize "Increase right"; }
        bind "Alt n" { SwitchToMode "normal"; }
    }
    move {
        bind "left" { MovePane "left"; }
        bind "down" { MovePane "down"; }
        bind "up" { MovePane "up"; }
        bind "right" { MovePane "right"; }
        bind "h" { MovePane "left"; }
        bind "Alt h" { SwitchToMode "normal"; }
        bind "j" { MovePane "down"; }
        bind "k" { MovePane "up"; }
        bind "l" { MovePane "right"; }
        bind "n" { MovePane; }
        bind "p" { MovePaneBackwards; }
        bind "tab" { MovePane; }
    }
    scroll {
        bind "e" { EditScrollback; SwitchToMode "normal"; }
        bind "s" { SwitchToMode "entersearch"; SearchInput 0; }
        bind "Alt s" { SwitchToMode "normal"; }
    }
    search {
        bind "c" { SearchToggleOption "CaseSensitivity"; }
        bind "n" { Search "down"; }
        bind "o" { SearchToggleOption "WholeWord"; }
        bind "p" { Search "up"; }
        bind "w" { SearchToggleOption "Wrap"; }
    }
    session {
        bind "a" {
            LaunchOrFocusPlugin "zellij:about" {
                floating true
                move_to_focused_tab true
            }
            SwitchToMode "normal"
        }
        bind "c" {
            LaunchOrFocusPlugin "configuration" {
                floating true
                move_to_focused_tab true
            }
            SwitchToMode "normal"
        }
        bind "Alt o" { SwitchToMode "normal"; }
        bind "p" {
            LaunchOrFocusPlugin "plugin-manager" {
                floating true
                move_to_focused_tab true
            }
            SwitchToMode "normal"
        }
        bind "s" {
            LaunchOrFocusPlugin "zellij:share" {
                floating true
                move_to_focused_tab true
            }
            SwitchToMode "normal"
        }
        bind "w" {
            LaunchOrFocusPlugin "session-manager" {
                floating true
                move_to_focused_tab true
            }
            SwitchToMode "normal"
        }
    }
    shared {
        bind "Alt left" { MoveFocusOrTab "left"; }
        bind "Alt down" { MoveFocus "down"; }
        bind "Alt up" { MoveFocus "up"; }
        bind "Alt right" { MoveFocusOrTab "right"; }
        bind "Alt +" { Resize "Increase"; }
        bind "Alt -" { Resize "Decrease"; }
        bind "Alt =" { Resize "Increase"; }
        bind "Alt [" { PreviousSwapLayout; }
        bind "Alt ]" { NextSwapLayout; }
        bind "Alt f" { ToggleFloatingPanes; }
        bind "Alt i" { MoveTab "left"; }
        bind "Alt j" { MoveFocus "down"; }
        bind "Alt k" { MoveFocus "up"; }
        bind "Alt l" { MoveFocusOrTab "right"; }
    }
    shared_except "locked" {
        bind "Alt Shift p" { ToggleGroupMarking; }
    }
    shared_except "locked" "entersearch" "renametab" "renamepane" "move" "prompt" "tmux" {
        bind "Alt h" { SwitchToMode "move"; }
    }
    shared_except "locked" "entersearch" "renametab" "renamepane" "prompt" "tmux" {
        bind "Alt g" { SwitchToMode "locked"; }
        bind "Alt q" { Quit; }
    }
    shared_except "locked" "entersearch" "renametab" "renamepane" "session" "prompt" "tmux" {
        bind "Alt o" { SwitchToMode "session"; }
    }
    shared_except "locked" "scroll" "search" "tmux" {
        bind "Ctrl b" { SwitchToMode "tmux"; }
    }
    shared_except "locked" "scroll" "entersearch" "renametab" "renamepane" "prompt" "tmux" {
        bind "Alt s" { SwitchToMode "scroll"; }
    }
    shared_except "locked" "tab" "entersearch" "renametab" "renamepane" "prompt" "tmux" {
        bind "Alt t" { SwitchToMode "tab"; }
    }
    shared_except "locked" "pane" "entersearch" "renametab" "renamepane" "prompt" "tmux" {
        bind "Alt p" { SwitchToMode "pane"; }
    }
    shared_except "locked" "resize" "entersearch" "renametab" "renamepane" "prompt" "tmux" {
        bind "Alt n" { SwitchToMode "resize"; }
    }
    shared_among "locked" "entersearch" "renametab" "renamepane" "prompt" "tmux" {
        bind "Alt h" { MoveFocusOrTab "left"; }
        bind "Alt n" { NewPane; }
        bind "Alt o" { MoveTab "right"; }
    }
    shared_except "normal" "locked" "entersearch" {
        bind "enter" { SwitchToMode "normal"; }
    }
    shared_except "normal" "locked" "entersearch" "renametab" "renamepane" {
        bind "esc" { SwitchToMode "normal"; }
    }
    shared_among "pane" "tmux" {
        bind "x" { CloseFocus; SwitchToMode "normal"; }
    }
    shared_among "scroll" "search" {
        bind "PageDown" { PageScrollDown; }
        bind "PageUp" { PageScrollUp; }
        bind "left" { PageScrollUp; }
        bind "down" { ScrollDown; }
        bind "up" { ScrollUp; }
        bind "right" { PageScrollDown; }
        bind "Ctrl b" { PageScrollUp; }
        bind "Ctrl c" { ScrollToBottom; SwitchToMode "normal"; }
        bind "d" { HalfPageScrollDown; }
        bind "Ctrl f" { PageScrollDown; }
        bind "h" { PageScrollUp; }
        bind "j" { ScrollDown; }
        bind "k" { ScrollUp; }
        bind "l" { PageScrollDown; }
        bind "u" { HalfPageScrollUp; }
    }
    entersearch {
        bind "Ctrl c" { SwitchToMode "scroll"; }
        bind "esc" { SwitchToMode "scroll"; }
        bind "enter" { SwitchToMode "search"; }
    }
    shared_among "entersearch" "renametab" "renamepane" "prompt" "tmux" {
        bind "Ctrl g" { SwitchToMode "locked"; }
        bind "Ctrl h" { SwitchToMode "move"; }
        bind "Ctrl n" { SwitchToMode "resize"; }
        bind "Ctrl o" { SwitchToMode "session"; }
        bind "Ctrl p" { SwitchToMode "pane"; }
        bind "Alt p" { TogglePaneInGroup; }
        bind "Ctrl q" { Quit; }
        bind "Ctrl s" { SwitchToMode "scroll"; }
        bind "Ctrl t" { SwitchToMode "tab"; }
    }
    renametab {
        bind "esc" { UndoRenameTab; SwitchToMode "tab"; }
    }
    shared_among "renametab" "renamepane" {
        bind "Ctrl c" { SwitchToMode "normal"; }
    }
    renamepane {
        bind "esc" { UndoRenamePane; SwitchToMode "pane"; }
    }
    shared_among "session" "tmux" {
        bind "d" { Detach; }
    }
    tmux {
        bind "left" { MoveFocus "left"; SwitchToMode "normal"; }
        bind "down" { MoveFocus "down"; SwitchToMode "normal"; }
        bind "up" { MoveFocus "up"; SwitchToMode "normal"; }
        bind "right" { MoveFocus "right"; SwitchToMode "normal"; }
        bind "space" { NextSwapLayout; }
        bind "\"" { NewPane "down"; SwitchToMode "normal"; }
        bind "%" { NewPane "right"; SwitchToMode "normal"; }
        bind "," { SwitchToMode "renametab"; }
        bind "[" { SwitchToMode "scroll"; }
        bind "Ctrl b" { Write 2; SwitchToMode "normal"; }
        bind "c" { NewTab; SwitchToMode "normal"; }
        bind "h" { MoveFocus "left"; SwitchToMode "normal"; }
        bind "j" { MoveFocus "down"; SwitchToMode "normal"; }
        bind "k" { MoveFocus "up"; SwitchToMode "normal"; }
        bind "l" { MoveFocus "right"; SwitchToMode "normal"; }
        bind "n" { GoToNextTab; SwitchToMode "normal"; }
        bind "o" { FocusNextPane; }
        bind "p" { GoToPreviousTab; SwitchToMode "normal"; }
        bind "z" { ToggleFocusFullscreen; SwitchToMode "normal"; }
    }
}

// Plugin aliases - can be used to change the implementation of Zellij
// changing these requires a restart to take effect
plugins {
    about location="zellij:about"
    compact-bar location="zellij:compact-bar"
    configuration location="zellij:configuration"
    filepicker location="zellij:strider" {
        cwd "/"
    }
    plugin-manager location="zellij:plugin-manager"
    session-manager location="zellij:session-manager"
    status-bar location="zellij:status-bar"
    strider location="zellij:strider"
    tab-bar location="zellij:tab-bar"
    welcome-screen location="zellij:session-manager" {
        welcome_screen true
    }
}

// Plugins to load in the background when a new session starts
// eg. "file:/path/to/my-plugin.wasm"
// eg. "https://example.com/my-plugin.wasm"
load_plugins {
}
web_client {
    font "monospace"
}

// Whether to show tips on startup
show_startup_tips false
ZELLIJ_KDL_EOF
}

# Writes ~/.bash_aliases (sourced near the end of the stock Ubuntu ~/.bashrc,
# so it can override the history defaults set earlier in that file).
# Usage: write_bash_aliases <target_file>
write_bash_aliases() {
    cat > "$1" << 'ALIASES_EOF'
# uhoh — rerun the previous command with sudo (like `sudo !!`)
uhoh() {
    local last
    last=$(fc -ln -1)
    last="${last#"${last%%[![:space:]]*}"}"   # trim leading whitespace
    if [[ -z "$last" ]]; then
        echo "uhoh: no previous command" >&2
        return 1
    fi
    echo "uhoh: sudo $last" >&2
    # bash -c keeps pipes/redirections inside the sudo context
    sudo bash -c "$last"
}

# History: large, deduplicated, shared across zellij panes
# (overrides the stock .bashrc values; histappend is already set there)
HISTSIZE=100000
HISTFILESIZE=200000
HISTCONTROL=ignoreboth:erasedups
PROMPT_COMMAND="history -a${PROMPT_COMMAND:+; $PROMPT_COMMAND}"

# Terminal CWD reporting for Tabby SFTP panel sync.
# Inside Zellij over SSH: emit custom OSC 7727 directly to the outer SSH PTY
# (Zellij intercepts OSC 7 internally but passes unknown OSC numbers through;
# the tabby-zellij-sudo plugin reads OSC 7727 and moves the SFTP panel).
# Outside Zellij: emit standard OSC 7 which Tabby handles natively.
_report_cwd() {
    local encoded="" i char hex
    for (( i=0; i<${#PWD}; i++ )); do
        char="${PWD:$i:1}"
        case "$char" in
            [a-zA-Z0-9/._~:-]) encoded+="$char" ;;
            *) printf -v hex '%%%02X' "'$char"; encoded+="$hex" ;;
        esac
    done
    if [ -n "${ZELLIJ:-}" ] && [ -w "${SSH_TTY:-}" ]; then
        printf '\033]7727;CWD=%s\007' "$encoded" > "$SSH_TTY"
    else
        printf '\033]7;file://%s%s\007' "${HOSTNAME}" "${encoded}"
    fi
}
PROMPT_COMMAND="_report_cwd${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
ALIASES_EOF
}
################################################################################
# MODE AUTO-DETECTION
################################################################################
# Detects which phase to run when no mode argument is given:
#   live USB (casper/overlay root)         → initial
#   installed system, postreboot pending   → postreboot
#   installed system, postreboot done      → reinstall-zbm (after confirmation)
# Sets the global MODE variable or exits with usage on failure.
detect_mode() {
    local root_fstype conf _ans
    root_fstype=$(findmnt -n -o FSTYPE / 2>/dev/null || echo "")
    # Conf lives next to the script (same convention as the postreboot loader)
    conf="$(dirname "$0")/zbm-installer.conf"

    if [[ "$root_fstype" == "zfs" ]]; then
        if [[ -f "$conf" ]] && grep -q '^POSTREBOOT_DONE="y"' "$conf"; then
            echo "Detected: installed system, post-reboot setup already completed."
            read -rp "Reinstall/update ZFSBootMenu now? [y/N]: " _ans
            if [[ ! "$_ans" =~ ^[Yy]$ ]]; then
                echo "Nothing to do."
                exit 0
            fi
            MODE="reinstall-zbm"
        else
            echo "Detected: installed system, post-reboot setup pending."
            MODE="postreboot"
        fi
    elif grep -qw 'boot=casper' /proc/cmdline 2>/dev/null \
         || [[ -d /run/casper ]] || [[ "$root_fstype" == "overlay" ]]; then
        echo "Detected: live USB environment."
        MODE="initial"
    else
        echo "Error: could not detect environment (root fstype: ${root_fstype:-unknown})."
        echo ""
        echo "Usage: $0 [initial|postreboot|reinstall-zbm]"
        echo ""
        echo "  initial       - Run from live USB to install system"
        echo "  postreboot    - Run after first boot to complete setup"
        echo "  reinstall-zbm - Reinstall or update ZFSBootMenu to latest version"
        exit 1
    fi
}

################################################################################
# POSTREBOOT SOFTWARE SELECTION & INSTALLATION
################################################################################
# Interactive software selection for postreboot. Every question is asked here,
# up front, so the installation steps that follow run unattended.
# Sets all INSTALL_* / SMTP_* / ADMIN_EMAIL globals.
prompt_postreboot_software() {
    echo ""
    echo "--- Optional software ---"
    echo "    Everything is asked now; installation runs unattended afterwards."

    echo ""
    echo "  [Containers & virtualization]"
    ask_yn "Install Docker Engine (official apt repo, not snap)?" y INSTALL_DOCKER docker-ce
    ask_yn "Install Podman (rootless containers, Ubuntu archive)?" n INSTALL_PODMAN podman
    ask_yn "Install KVM/libvirt headless virtualization (qemu, libvirt, virtinst)?" n INSTALL_VIRT libvirt-daemon-system

    echo ""
    echo "  [System health & updates]"
    ask_yn "Install disk/pool health monitoring (smartmontools, ZED mail, monthly scrub)?" y INSTALL_HEALTH smartmontools
    ask_yn "Enable unattended security upgrades (snapshot is taken by the existing apt hook)?" y INSTALL_UNATTENDED unattended-upgrades

    if [[ "$INSTALL_HEALTH" == "y" || "$INSTALL_UNATTENDED" == "y" ]]; then
        prompt_admin_email
        ask_yn "Configure an SMTP relay (msmtp) so this mail actually leaves the machine?" y INSTALL_MTA msmtp
        if [[ "$INSTALL_MTA" == "y" ]]; then
            prompt_smtp_relay
        else
            echo "    Note: without an MTA the alert mail stays in the local root mailbox."
        fi
    fi

    echo ""
    echo "  [Remote access & security]"
    ask_yn "Install Tailscale (mesh VPN)?" n INSTALL_TAILSCALE tailscale
    if [[ "$INSTALL_TAILSCALE" == "y" ]]; then
        read -rsp "    Tailscale auth key (tskey-…, empty = run 'tailscale up' manually later): " TAILSCALE_AUTHKEY
        echo ""
    fi
    # Not a package — the drop-in this script writes is the marker
    local ssh_default="n"
    if [[ -f /etc/ssh/sshd_config.d/10-zbm-hardening.conf ]]; then ssh_default="y"; fi
    ask_yn "Harden SSH (key-only login, no root login)?" "$ssh_default" HARDEN_SSH
    if [[ "$HARDEN_SSH" == "y" ]]; then
        local akeys
        akeys="$(getent passwd "$USERNAME" | cut -d: -f6)/.ssh/authorized_keys"
        if [[ ! -s "$akeys" ]]; then
            echo "    ⚠ $akeys is missing or empty — disabling password login locks you out"
            echo "      of SSH until you copy a key in (console access still works)."
            ask_yn "  Disable password login anyway?" n HARDEN_SSH_FORCE
            if [[ "$HARDEN_SSH_FORCE" != "y" ]]; then
                echo "    → password login stays enabled; only root login and X11 forwarding are disabled."
            fi
        else
            HARDEN_SSH_FORCE="y"
        fi
    fi
    ask_yn "Install ufw host firewall (default deny incoming)?" n INSTALL_UFW ufw
    ask_yn "Install fail2ban (SSH brute-force protection)?" n INSTALL_FAIL2BAN fail2ban
    ask_yn "Install NUT (UPS monitoring / clean shutdown on power loss)?" n INSTALL_NUT nut-server
    ask_yn "Install Cockpit web administration (https://<host>:9090)?" n INSTALL_COCKPIT cockpit

    echo ""
    echo "  [File & monitoring services]"
    ask_yn "Install Samba (SMB/CIFS file server)?" n INSTALL_SAMBA samba
    ask_yn "Install NFS server?" n INSTALL_NFS nfs-kernel-server
    ask_yn "Install prometheus-node-exporter (metrics on :9100)?" n INSTALL_NODEEXP prometheus-node-exporter
    ask_yn "Install netdata (dashboard on :19999)?" n INSTALL_NETDATA netdata

    echo ""
    echo "  [Shell tools]"
    ask_yn "Install shell toolbelt (git, rsync, jq, tree, fzf, ripgrep, bat, unzip)?" y INSTALL_TOOLBELT ripgrep

    # fail2ban and unattended-upgrades mail to the admin too — make sure the
    # address exists even when health monitoring itself was declined
    if [[ -z "$ADMIN_EMAIL" ]] && [[ "$INSTALL_FAIL2BAN" == "y" ]]; then
        prompt_admin_email
    fi
    [[ -z "$ADMIN_EMAIL" ]] && ADMIN_EMAIL="root"
    return 0
}

# True when dpkg reports the package as installed (not merely known).
pkg_installed() {
    [[ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null)" == "installed" ]]
}

# ask_yn <question> <default: y|n> <variable name> [package …]
# Writes "y" or "n" into the named variable. Empty input takes the default.
#
# The default is not blindly the built-in one — a re-run must not propose to
# undo what the last run did:
#   1. an answer carried over from zbm-installer.conf wins, then
#   2. a package that is already installed defaults the answer to "y".
# Either way an already-present component is marked "(installed)".
ask_yn() {
    local question="$1" default="$2" varname="$3"
    shift 3
    local input hint tag="" pkg
    local current="${!varname:-}"

    for pkg in "$@"; do
        if pkg_installed "$pkg"; then
            tag=" (installed)"
            default="y"
            break
        fi
    done
    if [[ "$current" == "y" || "$current" == "n" ]]; then default="$current"; fi

    if [[ "$default" == "y" ]]; then hint="[Y/n]"; else hint="[y/N]"; fi
    read -rp "    $question$tag $hint: " input
    if [[ -z "$input" ]]; then
        printf -v "$varname" '%s' "$default"
    elif [[ "$input" =~ ^[Yy] ]]; then
        printf -v "$varname" '%s' "y"
    else
        printf -v "$varname" '%s' "n"
    fi
}

# Writes NAME="value" into zbm-installer.conf, replacing an existing line so
# the file never grows duplicates. Values are plain identifiers, paths and
# addresses; secrets are never passed in — the SMTP password lives only in
# /etc/msmtprc.
persist_conf_var() {
    local name="$1" value="$2" conf="${INSTALL_CONF:-}"
    [[ -n "$conf" && -f "$conf" ]] || return 0
    if grep -q "^${name}=" "$conf"; then
        local esc
        esc=$(printf '%s' "$value" | sed 's/[&|\\]/\\&/g')
        sed -i "s|^${name}=.*|${name}=\"${esc}\"|" "$conf"
    else
        printf '%s="%s"\n' "$name" "$value" >> "$conf"
    fi
}

# Persists the software selection so a later postreboot run proposes what this
# run actually did instead of falling back to the built-in defaults, and so the
# chosen storage pool stays stable when a second pool appears later.
persist_postreboot_selection() {
    local v
    for v in INSTALL_DOCKER INSTALL_PODMAN INSTALL_VIRT INSTALL_HEALTH \
             INSTALL_UNATTENDED INSTALL_MTA INSTALL_TAILSCALE HARDEN_SSH \
             HARDEN_SSH_FORCE INSTALL_UFW INSTALL_FAIL2BAN INSTALL_NUT \
             INSTALL_COCKPIT INSTALL_SAMBA INSTALL_NFS INSTALL_NODEEXP \
             INSTALL_NETDATA INSTALL_TOOLBELT ADMIN_EMAIL SMTP_HOST SMTP_PORT \
             SMTP_USER MAIL_FROM STORAGE_POOL STORAGE_BASE DOCKER_DATA_ROOT \
             VIRT_STORAGE_DIR; do
        persist_conf_var "$v" "${!v:-}"
    done
    echo "  ✓ Software selection saved to $INSTALL_CONF (the SMTP password is not stored there)"
}

# Destination address for smartd, ZED, fail2ban and unattended-upgrades mail.
# "root" (the local mailbox) is the fallback when nothing is entered.
prompt_admin_email() {
    if [[ -n "$ADMIN_EMAIL" ]]; then
        return 0
    fi
    local input
    while true; do
        read -rp "    Admin e-mail for alerts (empty = local 'root' mailbox): " input
        if [[ -z "$input" ]]; then
            ADMIN_EMAIL="root"
            return 0
        fi
        if [[ "$input" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
            ADMIN_EMAIL="$input"
            return 0
        fi
        echo "    Invalid address."
    done
}

# SMTP relay details for msmtp. The password is kept in memory and written only
# to /etc/msmtprc (mode 600) — never to zbm-installer.conf or a temp file.
prompt_smtp_relay() {
    local input keep_hint=""
    # Values carried over from zbm-installer.conf are offered as defaults; the
    # password is never persisted, so an empty answer means "keep the one that
    # is already in /etc/msmtprc"
    [[ -f /etc/msmtprc ]] && keep_hint=" (empty = keep the current one)"

    while true; do
        read -rp "    SMTP relay host${SMTP_HOST:+ [$SMTP_HOST]}: " input
        if [[ -n "$input" ]]; then SMTP_HOST="$input"; fi
        if [[ -n "$SMTP_HOST" ]]; then break; fi
        echo "    A relay host is required."
    done

    read -rp "    SMTP port [587 = STARTTLS, 465 = implicit TLS] (${SMTP_PORT:-587}): " input
    if [[ -n "$input" ]]; then SMTP_PORT="$input"; fi
    if [[ -z "$SMTP_PORT" ]]; then SMTP_PORT="587"; fi

    read -rp "    SMTP username${SMTP_USER:+ [$SMTP_USER]}: " input
    if [[ -n "$input" ]]; then SMTP_USER="$input"; fi

    read -rsp "    SMTP password${keep_hint}: " input
    echo ""
    if [[ -n "$input" ]]; then SMTP_PASS="$input"; fi

    local from_default="${MAIL_FROM:-${SMTP_USER:-root@$HOSTNAME}}"
    read -rp "    Sender address (From:) [$from_default]: " input
    MAIL_FROM="${input:-$from_default}"
}

# Picks the pool that receives the software datasets (docker/virtmanager).
# Candidates are all imported pools except rpool whose root dataset has a real
# mountpoint (needed because the datasets inherit it). One candidate → used
# automatically; several → interactive menu with rpool as explicit fallback;
# none → rpool.
# Sets globals: STORAGE_POOL, STORAGE_BASE
select_storage_pool() {
    local -a pools=() bases=()
    local p mp
    while IFS= read -r p; do
        [[ "$p" == "rpool" ]] && continue
        mp=$(zfs get -H -o value mountpoint "$p")
        if [[ "$mp" == /* ]]; then
            pools+=("$p")
            bases+=("$mp")
        else
            echo "  (pool '$p' has mountpoint '$mp' — not offered for software datasets)"
        fi
    done < <(zpool list -H -o name)

    if (( ${#pools[@]} == 0 )); then
        STORAGE_POOL="rpool"
        STORAGE_BASE=""
    elif (( ${#pools[@]} == 1 )); then
        STORAGE_POOL="${pools[0]}"
        STORAGE_BASE="${bases[0]}"
    else
        local i choice n_opts=$(( ${#pools[@]} + 1 ))
        echo ""
        echo "Several pools can hold the software datasets (docker/virtmanager):"
        for i in "${!pools[@]}"; do
            printf "  %d) %-16s (mounted at %s)\n" "$((i+1))" "${pools[$i]}" "${bases[$i]}"
        done
        printf "  %d) %-16s (system pool; datasets mount at /docker, /virtmanager)\n" "$n_opts" "rpool"
        while true; do
            read -rp "Select pool [1-$n_opts]: " choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= n_opts )); then
                break
            fi
            echo "  Invalid selection."
        done
        if (( choice == n_opts )); then
            STORAGE_POOL="rpool"
            STORAGE_BASE=""
        else
            STORAGE_POOL="${pools[$((choice-1))]}"
            STORAGE_BASE="${bases[$((choice-1))]}"
        fi
    fi
}

# Creates ZFS datasets for the selected software on the given pool (idempotent).
# Usage: create_software_datasets <pool> <mount_base>
#   datapool: <pool>=$DATAPOOL_NAME, <mount_base>=$DATAPOOL_MOUNTPOINT
#             (pool has a real mountpoint → children inherit it)
#   rpool:    <pool>=rpool, <mount_base>=""
#             (rpool root is mountpoint=none → parents get explicit mountpoints)
# Sets globals: DOCKER_DATA_ROOT, VIRT_STORAGE_DIR
create_software_datasets() {
    local pool="$1" base="$2"
    local -a mp_docker=() mp_virt=()
    if [[ "$pool" == "rpool" ]]; then
        mp_docker=(-o mountpoint=/docker)
        mp_virt=(-o mountpoint=/virtmanager)
    fi

    if [[ "$INSTALL_DOCKER" == "y" ]]; then
        echo "  - Creating Docker datasets under $pool/docker..."

        # Parent dataset — inherits pool compression/atime
        zfs list "$pool/docker" &>/dev/null || \
            zfs create ${mp_docker[@]+"${mp_docker[@]}"} "$pool/docker"

        # dockerroot: Docker's data-root (overlay2 layers, images, containers)
        #   recordsize=16K   — overlay2 writes in small blocks
        #   xattr=sa         — required for overlay2
        #   acltype=posixacl — required for overlay2
        zfs list "$pool/docker/dockerroot" &>/dev/null || \
            zfs create \
                -o recordsize=16K \
                -o xattr=sa \
                -o acltype=posixacl \
                "$pool/docker/dockerroot"

        # storage: external volume data mounted into containers
        #   default recordsize (128K) suits mixed file sizes
        #   xattr/acltype are set explicitly here too — the pool-level defaults
        #   only exist on datapools this script created, not on rpool or on an
        #   imported pool
        zfs list "$pool/docker/storage" &>/dev/null || \
            zfs create \
                -o xattr=sa \
                -o acltype=posixacl \
                "$pool/docker/storage"

        # stack: docker-compose files (small text files)
        #   recordsize=4K — minimises wasted space for tiny config files
        zfs list "$pool/docker/stack" &>/dev/null || \
            zfs create \
                -o recordsize=4K \
                "$pool/docker/stack"

        DOCKER_DATA_ROOT="$base/docker/dockerroot"
        echo "  ✓ Docker datasets created"
    fi

    if [[ "$INSTALL_VIRT" == "y" ]]; then
        echo "  - Creating virtualization datasets under $pool/virtmanager..."

        zfs list "$pool/virtmanager" &>/dev/null || \
            zfs create ${mp_virt[@]+"${mp_virt[@]}"} "$pool/virtmanager"

        # storage: VM disk images
        #   recordsize=64K — matches qcow2 default cluster size
        zfs list "$pool/virtmanager/storage" &>/dev/null || \
            zfs create \
                -o recordsize=64K \
                "$pool/virtmanager/storage"

        VIRT_STORAGE_DIR="$base/virtmanager/storage"
        echo "  ✓ Virtualization datasets created"
    fi
}

# Reports the data-root dockerd is currently configured for, or "" when
# /etc/docker/daemon.json has no data-root key (dockerd default: /var/lib/docker).
current_docker_data_root() {
    [[ -f /etc/docker/daemon.json ]] || return 0
    sed -n 's/.*"data-root"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        /etc/docker/daemon.json | head -1
}

# Repoints an already-installed Docker at DOCKER_DATA_ROOT. Existing image and
# container data is never moved automatically — that is the user's call — so a
# non-empty current data-root is reported and confirmed first.
repoint_existing_docker() {
    local current effective
    current=$(current_docker_data_root)
    effective="${current:-/var/lib/docker}"

    if [[ "$effective" == "$DOCKER_DATA_ROOT" ]]; then
        echo "  ✓ Docker already using data-root $DOCKER_DATA_ROOT"
        return 0
    fi

    echo "  - Docker is installed with data-root: $effective"
    echo "    The datasets created above expect:   $DOCKER_DATA_ROOT"

    # Anything beyond an empty dir means images/containers/volumes would become
    # invisible after the switch
    local has_data="no"
    if [[ -d "$effective" ]] && [[ -n "$(ls -A "$effective" 2>/dev/null)" ]]; then
        has_data="yes"
        echo "    ⚠ $effective is NOT empty — existing images, containers and"
        echo "      volumes will become invisible until you migrate them, e.g.:"
        echo "        systemctl stop docker && rsync -aHAX $effective/ $DOCKER_DATA_ROOT/"
    fi

    local _ans
    if [[ "$has_data" == "yes" ]]; then
        read -rp "  Repoint Docker to $DOCKER_DATA_ROOT anyway? [y/N]: " _ans
    else
        read -rp "  Repoint Docker to $DOCKER_DATA_ROOT? [Y/n]: " _ans
        # Plain `[[ ]] && cmd` would abort the run under set -e whenever the
        # test fails, i.e. whenever the user actually typed an answer
        if [[ -z "$_ans" ]]; then _ans="y"; fi
    fi
    if [[ ! "$_ans" =~ ^[Yy]$ ]]; then
        echo "  ✓ Leaving Docker data-root at $effective"
        return 0
    fi

    systemctl stop docker 2>/dev/null || true
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json << DOCKEREOF
{
    "data-root": "$DOCKER_DATA_ROOT",
    "storage-driver": "overlay2"
}
DOCKEREOF
    systemctl start docker
    echo "  ✓ Docker data-root set to $DOCKER_DATA_ROOT"
}

# Installs Docker Engine on the running system. daemon.json (data-root) is
# written BEFORE installation so dockerd never populates /var/lib/docker.
# Requires: DOCKER_DATA_ROOT set by create_software_datasets().
install_docker_postreboot() {
    if command -v docker &>/dev/null; then
        echo "  ✓ Docker already installed — checking data-root"
        repoint_existing_docker
        # Keep group membership idempotent for re-runs
        usermod -aG docker "$USERNAME"
        return 0
    fi

    # 1. daemon.json first — the package postinst starts dockerd, which must
    #    already see the ZFS-backed data-root
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json << DOCKEREOF
{
    "data-root": "$DOCKER_DATA_ROOT",
    "storage-driver": "overlay2"
}
DOCKEREOF

    # 2. Docker's official apt repo
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    local codename arch
    codename=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
    arch=$(dpkg --print-architecture)
    cat > /etc/apt/sources.list.d/docker.sources << SRCEOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $codename
Components: stable
Architectures: $arch
Signed-By: /etc/apt/keyrings/docker.asc
SRCEOF

    # 3. Install — postinst starts dockerd with the daemon.json above
    apt update
    apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # 4. Group membership (takes effect on next login)
    usermod -aG docker "$USERNAME"
    echo "  ✓ Docker $(docker --version) installed, data-root: $DOCKER_DATA_ROOT"
    echo "  ✓ User $USERNAME added to 'docker' group"
}

# Installs headless KVM/libvirt and points the libvirt "default" storage pool
# at the ZFS-backed VIRT_STORAGE_DIR. No GUI (virt-manager connects remotely).
# Requires: VIRT_STORAGE_DIR set by create_software_datasets().
install_virtualization_postreboot() {
    # dnsmasq-base is only a Recommends of libvirt-daemon-system — with
    # --no-install-recommends it must be listed explicitly or the "default"
    # NAT network cannot start (VMs would have no networking)
    # Package lists may be stale when Docker was not selected (which is what
    # otherwise runs apt update on this boot)
    apt update
    apt install -y --no-install-recommends \
        qemu-system-x86 \
        libvirt-daemon-system \
        libvirt-clients \
        virtinst \
        ovmf \
        dnsmasq-base

    # Recent libvirt splits the monolithic libvirtd into modular daemons, so
    # libvirtd.service is not guaranteed to exist. Enable whichever is present
    # and let the socket-activated units cover the rest.
    if systemctl list-unit-files libvirtd.service &>/dev/null \
       && systemctl enable --now libvirtd 2>/dev/null; then
        echo "  ✓ libvirtd enabled"
    else
        systemctl enable --now virtqemud.socket virtnetworkd.socket virtstoraged.socket 2>/dev/null || true
        echo "  ✓ modular libvirt daemons enabled"
    fi
    usermod -aG libvirt "$USERNAME"

    # Bring up the default NAT network now and on every boot.
    # Non-fatal: a missing/renamed default network must not abort postreboot
    # after Docker and the datapool are already in place.
    virsh net-autostart default 2>/dev/null || echo "  ⚠ could not autostart libvirt 'default' network"
    virsh net-start default 2>/dev/null || true  # fails harmlessly if already active

    # Define the default storage pool on ZFS (idempotent)
    if ! virsh pool-info default &>/dev/null; then
        if virsh pool-define-as default dir --target "$VIRT_STORAGE_DIR"; then
            virsh pool-build default 2>/dev/null || true  # dir already exists (dataset mountpoint)
            virsh pool-start default    2>/dev/null || true
            virsh pool-autostart default 2>/dev/null || true
            echo "  ✓ libvirt 'default' storage pool → $VIRT_STORAGE_DIR"
        else
            echo "  ⚠ Could not define the libvirt 'default' pool; create it manually:"
            echo "      virsh pool-define-as default dir --target $VIRT_STORAGE_DIR"
        fi
    else
        echo "  ✓ libvirt 'default' pool already defined, skipping"
    fi
    echo "  ✓ KVM/libvirt installed (user $USERNAME in 'libvirt' group; re-login required)"
}

################################################################################
# POSTREBOOT: SYSTEM HEALTH, SECURITY AND SERVICE INSTALLERS
################################################################################
# Package lists are refreshed once per postreboot run — the optional installers
# below all need current lists, but only the first one should pay for it.
apt_refresh() {
    if [[ "${APT_UPDATED:-0}" -eq 0 ]]; then
        apt update
        APT_UPDATED=1
    fi
}

# Config files below are edited in place, so every write is wrapped in a marker
# block that is stripped first. That keeps re-runs idempotent without ever
# clobbering settings the user or a package added around it.
ZBM_BLOCK_START="# >>> zbm-installer managed >>>"
ZBM_BLOCK_END="# <<< zbm-installer managed <<<"

strip_managed_block() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    sed -i "/^${ZBM_BLOCK_START}\$/,/^${ZBM_BLOCK_END}\$/d" "$file"
}

# --- Mail relay -------------------------------------------------------------
# msmtp-mta provides /usr/sbin/sendmail, which is what smartd, ZED, fail2ban and
# unattended-upgrades all expect. Without it their mail rots in the local spool.
install_mta_postreboot() {
    apt_refresh
    apt install -y --no-install-recommends msmtp msmtp-mta ca-certificates

    local starttls="on"
    if [[ "$SMTP_PORT" == "465" ]]; then starttls="off"; fi

    # The password is not kept in zbm-installer.conf, so on a re-run with an
    # empty answer it is recovered from the file it was written to
    if [[ -z "$SMTP_PASS" && -f /etc/msmtprc ]]; then
        SMTP_PASS=$(awk '$1 == "password" { $1 = ""; sub(/^[[:space:]]+/, ""); print; exit }' /etc/msmtprc)
    fi
    if [[ -z "$SMTP_PASS" ]]; then
        echo "  ⚠ No SMTP password available — msmtp will not be able to authenticate."
    fi

    # 0600 + root:root — this file holds the relay password in cleartext, which
    # is unavoidable for an unattended MTA
    install -m 600 -o root -g root /dev/null /etc/msmtprc
    cat > /etc/msmtprc << MSMTPEOF
# Written by zbm-ubuntu-server-installer
defaults
auth           on
tls            on
tls_starttls   $starttls
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        /var/log/msmtp.log
aliases        /etc/aliases

account        default
host           $SMTP_HOST
port           $SMTP_PORT
from           $MAIL_FROM
user           $SMTP_USER
password       $SMTP_PASS
MSMTPEOF
    chmod 600 /etc/msmtprc

    # Alias map so mail addressed to root (smartd, cron, ZED) is rewritten
    cat > /etc/aliases << ALIASEOF
root: $ADMIN_EMAIL
default: $ADMIN_EMAIL
ALIASEOF

    echo "  ✓ msmtp configured: $SMTP_USER@$SMTP_HOST:$SMTP_PORT → $ADMIN_EMAIL"
    echo "    Test with: echo test | mail -s 'zbm test' $ADMIN_EMAIL"
}

# --- Disk and pool health ---------------------------------------------------
# smartd watches the drives, ZED reports pool events, the scrub timers verify
# the data itself. A snapshotting server without these three is silently
# accumulating bad blocks.
install_health_postreboot() {
    apt_refresh
    # bsd-mailx supplies /usr/bin/mail for ZED, but it depends on a
    # mail-transport-agent — only pull it in once a sendmail binary exists
    # (msmtp-mta from the previous step, or one already on the system),
    # otherwise apt would drag postfix in behind it.
    local -a health_pkgs=(smartmontools)
    if [[ -x /usr/sbin/sendmail ]]; then
        health_pkgs+=(bsd-mailx)
    else
        echo "  ⚠ No MTA installed — smartd/ZED alerts stay on this machine."
        echo "    Re-run with the msmtp option, or install a mail-transport-agent."
    fi
    apt install -y --no-install-recommends "${health_pkgs[@]}"

    # smartd: short self-test nightly at 02:00, long self-test Saturdays 03:00,
    # temperature warnings, skip drives that are spun down
    strip_managed_block /etc/smartd.conf
    sed -i 's/^DEVICESCAN/#DEVICESCAN/' /etc/smartd.conf
    cat >> /etc/smartd.conf << SMARTDEOF
$ZBM_BLOCK_START
DEVICESCAN -a -o on -S on -n standby,q -W 4,45,55 -s (S/../.././02|L/../../6/03) -m $ADMIN_EMAIL -M exec /usr/share/smartmontools/smartd-runner
$ZBM_BLOCK_END
SMARTDEOF
    # Fails on hardware without SMART (VMs, some USB bridges) — not fatal
    systemctl enable smartd 2>/dev/null || true
    if systemctl restart smartd 2>/dev/null; then
        echo "  ✓ smartd monitoring active (alerts → $ADMIN_EMAIL)"
    else
        echo "  ⚠ smartd could not start (no SMART-capable devices?) — config is in place"
    fi

    # ZED: mail on pool events. zed.rc is sourced as shell, so the appended
    # block overrides whatever the package shipped further up.
    if [[ -f /etc/zfs/zed.d/zed.rc ]]; then
        strip_managed_block /etc/zfs/zed.d/zed.rc
        cat >> /etc/zfs/zed.d/zed.rc << ZEDEOF
$ZBM_BLOCK_START
ZED_EMAIL_ADDR="$ADMIN_EMAIL"
ZED_EMAIL_PROG="mail"
ZED_EMAIL_OPTS="-s '@SUBJECT@' @ADDRESS@"
ZED_NOTIFY_VERBOSE=1
ZED_NOTIFY_DATA=1
$ZBM_BLOCK_END
ZEDEOF
        systemctl restart zfs-zed 2>/dev/null || true
        echo "  ✓ ZED pool alerts → $ADMIN_EMAIL"
    else
        echo "  ⚠ /etc/zfs/zed.d/zed.rc not found — ZED mail not configured"
    fi

    # Monthly scrub for every imported pool (zfsutils-linux ships the template)
    if systemctl list-unit-files | grep -q '^zfs-scrub-monthly@\.timer'; then
        local p
        while IFS= read -r p; do
            systemctl enable --now "zfs-scrub-monthly@${p}.timer" 2>/dev/null \
                && echo "  ✓ monthly scrub enabled for pool '$p'" \
                || echo "  ⚠ could not enable monthly scrub for '$p'"
        done < <(zpool list -H -o name)
    else
        echo "  ⚠ zfs-scrub-monthly@.timer not available — add a scrub cron job manually"
    fi
}

# --- Unattended security upgrades -------------------------------------------
# Safe here because the APT pre-invoke hook from the initial install snapshots
# rpool before every dpkg run: a bad upgrade is one ZFSBootMenu rollback away.
# Automatic-Reboot stays off — rebooting a ZFS server unattended is not worth it.
install_unattended_upgrades_postreboot() {
    apt_refresh
    apt install -y --no-install-recommends unattended-upgrades

    cat > /etc/apt/apt.conf.d/52zbm-unattended-upgrades << UUEOF
// Written by zbm-ubuntu-server-installer
// Security pockets only — feature updates stay manual.
Unattended-Upgrade::Allowed-Origins {
    "\${distro_id}:\${distro_codename}-security";
    "\${distro_id}ESMApps:\${distro_codename}-apps-security";
    "\${distro_id}ESM:\${distro_codename}-infra-security";
};
Unattended-Upgrade::Mail "$ADMIN_EMAIL";
Unattended-Upgrade::MailReport "on-change";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "false";
Unattended-Upgrade::Automatic-Reboot "false";
UUEOF

    cat > /etc/apt/apt.conf.d/20auto-upgrades << AUEOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
AUEOF

    systemctl enable --now apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
    echo "  ✓ unattended-upgrades active (security pocket, no auto-reboot, report → $ADMIN_EMAIL)"
    echo "    Every run is preceded by a ZFS snapshot via /etc/apt/apt.conf.d/80-zfs-snapshot"
}

# --- Tailscale --------------------------------------------------------------
# The repo is keyed per Ubuntu codename; a brand-new release may not have one
# yet, so fall back to the previous LTS suite rather than failing the install.
install_tailscale_postreboot() {
    local codename suite="" c
    codename=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
    for c in "$codename" noble; do
        if curl -fsI "https://pkgs.tailscale.com/stable/ubuntu/${c}.noarmor.gpg" >/dev/null 2>&1; then
            suite="$c"
            break
        fi
    done
    if [[ -z "$suite" ]]; then
        echo "  ⚠ No Tailscale apt suite found for '$codename' — skipping."
        echo "    Install manually: curl -fsSL https://tailscale.com/install.sh | sh"
        return 0
    fi
    if [[ "$suite" != "$codename" ]]; then
        echo "  - No '$codename' suite yet, using '$suite'"
    fi

    curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${suite}.noarmor.gpg" \
        -o /usr/share/keyrings/tailscale-archive-keyring.gpg
    chmod a+r /usr/share/keyrings/tailscale-archive-keyring.gpg
    cat > /etc/apt/sources.list.d/tailscale.sources << TSEOF
Types: deb
URIs: https://pkgs.tailscale.com/stable/ubuntu
Suites: $suite
Components: main
Signed-By: /usr/share/keyrings/tailscale-archive-keyring.gpg
TSEOF

    apt update
    APT_UPDATED=1
    apt install -y tailscale
    systemctl enable --now tailscaled

    if [[ -n "$TAILSCALE_AUTHKEY" ]]; then
        if tailscale up --authkey "$TAILSCALE_AUTHKEY" --ssh; then
            echo "  ✓ Tailscale connected: $(tailscale ip -4 2>/dev/null | head -1)"
        else
            echo "  ⚠ 'tailscale up' failed — run it manually"
        fi
    else
        echo "  ✓ Tailscale installed — run 'sudo tailscale up --ssh' to join your tailnet"
    fi
}

# --- SSH hardening ----------------------------------------------------------
# The drop-in is numbered 10- on purpose: sshd takes the FIRST value it sees for
# a keyword, so a later 50-cloud-init.conf must not be able to re-enable
# password login. The config is validated and rolled back if sshd rejects it.
harden_ssh_postreboot() {
    local dropin=/etc/ssh/sshd_config.d/10-zbm-hardening.conf
    mkdir -p /etc/ssh/sshd_config.d

    {
        echo "# Written by zbm-ubuntu-server-installer"
        echo "PermitRootLogin no"
        echo "X11Forwarding no"
        echo "MaxAuthTries 4"
        if [[ "$HARDEN_SSH_FORCE" == "y" ]]; then
            echo "PasswordAuthentication no"
            echo "KbdInteractiveAuthentication no"
            echo "PubkeyAuthentication yes"
        fi
    } > "$dropin"

    if /usr/sbin/sshd -t 2>/dev/null; then
        systemctl reload ssh 2>/dev/null || systemctl restart ssh 2>/dev/null || true
        # Socket activation (Ubuntu 24.04+) serves new connections from the socket unit
        systemctl restart ssh.socket 2>/dev/null || true
        if [[ "$HARDEN_SSH_FORCE" == "y" ]]; then
            echo "  ✓ SSH hardened: key-only login, no root login"
        else
            echo "  ✓ SSH hardened: no root login (password login left enabled — no key present)"
        fi
    else
        rm -f "$dropin"
        echo "  ⚠ sshd rejected the hardening config — reverted, SSH left unchanged"
    fi
}

# --- Host firewall ----------------------------------------------------------
# Ports are opened from the selection flags, so this can run before the services
# themselves are installed. SSH is allowed before the firewall is enabled.
install_ufw_postreboot() {
    apt_refresh
    apt install -y --no-install-recommends ufw

    # No 'ufw --force reset': a re-run must not wipe rules added by hand later.
    # Every rule below is idempotent.
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    ufw allow 22/tcp comment 'SSH' >/dev/null

    if [[ "$INSTALL_TAILSCALE" == "y" ]]; then ufw allow in on tailscale0 comment 'Tailscale' >/dev/null; fi
    if [[ "$INSTALL_COCKPIT" == "y" ]];   then ufw allow 9090/tcp comment 'Cockpit' >/dev/null; fi
    if [[ "$INSTALL_NODEEXP" == "y" ]];   then ufw allow 9100/tcp comment 'node-exporter' >/dev/null; fi
    if [[ "$INSTALL_NETDATA" == "y" ]];   then ufw allow 19999/tcp comment 'netdata' >/dev/null; fi
    if [[ "$INSTALL_NFS" == "y" ]];       then ufw allow 2049/tcp comment 'NFSv4' >/dev/null; fi
    if [[ "$INSTALL_SAMBA" == "y" ]]; then
        ufw allow 445/tcp comment 'SMB' >/dev/null
        ufw allow 139/tcp comment 'NetBIOS session' >/dev/null
        ufw allow 137:138/udp comment 'NetBIOS name/datagram' >/dev/null
    fi

    ufw --force enable >/dev/null
    echo "  ✓ ufw enabled (default deny incoming; SSH and selected services allowed)"
    if [[ "$INSTALL_DOCKER" == "y" ]]; then
        echo "  ⚠ Docker inserts its own iptables rules ahead of ufw: published container"
        echo "    ports (-p) are reachable regardless of these rules. Bind them to"
        echo "    127.0.0.1 (-p 127.0.0.1:8080:80) or use ufw-docker if that matters."
    fi
}

# --- fail2ban ---------------------------------------------------------------
install_fail2ban_postreboot() {
    apt_refresh
    # python3-systemd is what lets the systemd backend read the journal
    apt install -y --no-install-recommends fail2ban python3-systemd

    local banaction="iptables-multiport"
    [[ "$INSTALL_UFW" == "y" ]] && banaction="ufw"

    mkdir -p /etc/fail2ban/jail.d
    cat > /etc/fail2ban/jail.d/zbm-sshd.local << F2BEOF
# Written by zbm-ubuntu-server-installer
[DEFAULT]
backend   = systemd
banaction = $banaction
bantime   = 1h
findtime  = 10m
maxretry  = 5
destemail = $ADMIN_EMAIL
sender    = root@$HOSTNAME

[sshd]
enabled = true
F2BEOF

    systemctl enable --now fail2ban 2>/dev/null || true
    if systemctl is-active --quiet fail2ban; then
        echo "  ✓ fail2ban active (sshd jail, ban action: $banaction)"
    else
        echo "  ⚠ fail2ban installed but not active — check 'journalctl -u fail2ban'"
    fi
}

# --- UPS monitoring ---------------------------------------------------------
# The UPS itself cannot be configured blind: driver, port and credentials depend
# on the model. Install, set standalone mode, then report what is attached.
install_nut_postreboot() {
    apt_refresh
    apt install -y --no-install-recommends nut-server nut-client

    echo "MODE=standalone" > /etc/nut/nut.conf

    echo "  ✓ NUT installed (MODE=standalone)"
    echo "  - Scanning for a USB UPS..."
    if command -v nut-scanner &>/dev/null && nut-scanner -q -U 2>/dev/null | grep -q '\['; then
        echo ""
        nut-scanner -q -U 2>/dev/null || true
        echo ""
        echo "    Paste the block above into /etc/nut/ups.conf, then:"
    else
        echo "    No USB UPS detected. Once one is attached, run 'nut-scanner -U' and"
        echo "    put the output in /etc/nut/ups.conf, then:"
    fi
    echo "      /etc/nut/upsd.users  → [upsmon] password + upsmon primary"
    echo "      /etc/nut/upsmon.conf → MONITOR <ups>@localhost 1 upsmon <pass> primary"
    echo "      systemctl restart nut-server nut-monitor"
}

# --- Cockpit ----------------------------------------------------------------
install_cockpit_postreboot() {
    apt_refresh
    local -a pkgs=(cockpit cockpit-storaged)
    # NetworkManager is not used here (systemd-networkd), so cockpit-networkmanager
    # is deliberately left out
    if [[ "$INSTALL_VIRT" == "y" ]];   then pkgs+=(cockpit-machines); fi
    if [[ "$INSTALL_PODMAN" == "y" ]]; then pkgs+=(cockpit-podman); fi
    apt install -y --no-install-recommends "${pkgs[@]}"

    systemctl enable --now cockpit.socket
    echo "  ✓ Cockpit on https://$HOSTNAME:9090 (self-signed certificate; log in as $USERNAME)"
    if [[ "$INSTALL_DOCKER" == "y" ]]; then
        echo "    Note: Cockpit has no Docker module — only Podman is supported."
    fi
}

# --- Podman -----------------------------------------------------------------
install_podman_postreboot() {
    apt_refresh
    # uidmap/slirp4netns/fuse-overlayfs are what make the rootless mode work;
    # fuse-overlayfs is also the storage driver that behaves on ZFS
    apt install -y --no-install-recommends \
        podman uidmap slirp4netns fuse-overlayfs
    echo "  ✓ Podman $(podman --version 2>/dev/null | awk '{print $3}') installed"
    echo "    Rootless storage lives in ~/.local/share/containers (per user)"
}

# --- File services ----------------------------------------------------------
# Shares are not defined here: which dataset gets exported to whom is a decision
# per machine. Both daemons are installed and enabled, ready to be pointed at a
# dataset.
install_samba_postreboot() {
    apt_refresh
    apt install -y --no-install-recommends samba
    systemctl enable --now smbd nmbd 2>/dev/null || systemctl enable --now smbd 2>/dev/null || true
    echo "  ✓ Samba installed"
    echo "    Add the user:  smbpasswd -a $USERNAME"
    echo "    Add a share:   edit /etc/samba/smb.conf (or 'zfs set sharesmb=on <dataset>')"
}

install_nfs_postreboot() {
    apt_refresh
    apt install -y --no-install-recommends nfs-kernel-server
    systemctl enable --now nfs-server 2>/dev/null || true
    echo "  ✓ NFS server installed"
    echo "    Export a dataset: zfs set sharenfs='rw=@192.168.0.0/24' <pool>/<dataset>"
}

# --- Metrics ----------------------------------------------------------------
install_nodeexp_postreboot() {
    apt_refresh
    apt install -y --no-install-recommends prometheus-node-exporter
    systemctl enable --now prometheus-node-exporter 2>/dev/null || true
    echo "  ✓ prometheus-node-exporter on :9100"
}

install_netdata_postreboot() {
    apt_refresh
    # netdata's dashboard needs its recommended plugin packages, so no
    # --no-install-recommends here
    apt install -y netdata
    systemctl enable --now netdata 2>/dev/null || true
    echo "  ✓ netdata on http://$HOSTNAME:19999 (archive version; upstream is newer)"
    echo "    It listens on all interfaces — restrict it in /etc/netdata/netdata.conf if exposed"
}

# --- Shell toolbelt ---------------------------------------------------------
install_toolbelt_postreboot() {
    apt_refresh
    apt install -y --no-install-recommends \
        git rsync jq tree fzf ripgrep bat unzip
    echo "  ✓ Shell tools installed (note: bat is called 'batcat' on Ubuntu)"
}

################################################################################
# INSTALLATION MODE
################################################################################
MODE="${1:-}"

if [[ -z "$MODE" ]]; then
    detect_mode
fi

################################################################################
# CLEANUP FUNCTION
################################################################################
cleanup_on_error() {
    echo ""
    echo "======================================================================"
    echo "Error: Installation failed! Cleaning up..."
    echo "======================================================================"

    # Prevent unmount propagation back to live host
    mount --make-rslave /mnt/dev  2>/dev/null || true
    mount --make-rslave /mnt/proc 2>/dev/null || true
    mount --make-rslave /mnt/sys  2>/dev/null || true

    # Unmount everything - handle busy mounts gracefully
    if ! umount -R /mnt 2>/dev/null; then
        # If recursive unmount fails, use lazy unmount for known busy mounts
        umount -l /mnt/sys/fs/cgroup 2>/dev/null || true
        umount -l /mnt/dev 2>/dev/null || true
        umount -l /mnt/proc 2>/dev/null || true
        umount -l /mnt/sys 2>/dev/null || true
        umount /mnt/boot/efi 2>/dev/null || true
        umount /mnt 2>/dev/null || true
    fi

    # Export pools if they exist
    zpool export rpool 2>/dev/null || true

    # Also export datapool if it was created during postreboot
    if [[ -n "${DATAPOOL_NAME:-}" ]]; then
        zpool export "$DATAPOOL_NAME" 2>/dev/null || true
    fi

    echo "Cleanup complete. Please check the errors above and try again."
}

################################################################################
# INITIAL INSTALLATION (Run from Live USB)
################################################################################
if [[ "$MODE" == "initial" ]]; then
    # Set up error trap
    trap cleanup_on_error ERR

    # ── PRE-FLIGHT CHECKS (abort before any user interaction) ──────────────────

    # Verify we're running as root
    if [[ $EUID -ne 0 ]]; then
        echo "This script must be run as root"
        exit 1
    fi

    # Verify EFI boot environment
    if [[ ! -d /sys/firmware/efi ]]; then
        echo "Error: EFI boot environment not found."
        echo "This script requires UEFI firmware. BIOS/legacy boot is not supported."
        exit 1
    fi
    echo "  ✓ EFI boot environment confirmed"

    # Verify network connectivity before any user interaction
    echo ""
    echo "Checking network connectivity..."
    if ! ping -c 1 -W 5 1.1.1.1 >/dev/null 2>&1 && ! ping -c 1 -W 5 9.9.9.9 >/dev/null 2>&1; then
        # ICMP may be blocked; try curl then wget as HTTPS fallback
        if ! curl -s --max-time 10 -o /dev/null https://archive.ubuntu.com 2>/dev/null \
            && ! wget -q --spider --timeout=10 https://archive.ubuntu.com 2>/dev/null; then
            echo "Error: No network connectivity detected (tested ICMP and HTTPS)!"
            echo "This script requires internet access for:"
            echo "  - Package downloads (apt, debootstrap)"
            echo "  - ZFSBootMenu git repository"
            echo "Please check your network connection and try again."
            exit 1
        fi
        echo "  ✓ Network connectivity verified (HTTPS - ICMP blocked)"
    else
        echo "  ✓ Network connectivity verified"
    fi

    # Prefer IPv4 for apt to avoid slow/unreachable IPv6 Ubuntu mirrors
    sed -i 's,#precedence ::ffff:0:0/96  100,precedence ::ffff:0:0/96  100,' /etc/gai.conf
    echo "  ✓ IPv4 preferred for apt (IPv6 workaround applied)"

    # ── INTERACTIVE CONFIGURATION ──────────────────────────────────────────────

    configure_interactively

    # Validate configuration inputs
    echo ""
    echo "Validating configuration..."
    validate_inputs
    echo "Configuration validated successfully."

    # Interactively select the target disk
    select_disk

    # Verify the selected disk block device exists
    if [[ ! -b "$DISK" ]]; then
        echo "Error: Disk $DISK not found after selection."
        exit 1
    fi

    # Validate that the disk is large enough for EFI + Swap + buffer
    echo ""
    echo "Validating disk size..."
    validate_disk_size "$DISK"

    # Interactively select rpool percentage and compute RPOOL_SIZE.
    # The percentage split only makes sense when a datapool shares this disk;
    # otherwise rpool takes everything (a percentage would leave the rest
    # unpartitioned and permanently unusable).
    if [[ "$DISK_SETUP_MODE" == "separate-disks" || -z "$DATAPOOL_NAME" ]]; then
        # rpool gets the full remaining disk — no percentage question
        _disk_bytes=$(blockdev --getsize64 "$DISK")
        _disk_mib=$(( _disk_bytes / 1024 / 1024 ))
        RPOOL_SIZE=$(( _disk_mib - EFI_SIZE - SWAP_SIZE - 2048 ))
        echo ""
        echo "rpool will use all remaining disk space: $(( RPOOL_SIZE / 1024 ))GiB"
    else
        select_rpool_percent "$DISK"
    fi

    # Show full confirmation table and require explicit YES before any destructive steps
    show_disk_confirmation "$DISK"

    # ── INSTALLATION (all user input done, nothing below is interactive) ────────

    # Start logging all output to a persistent install log
    INSTALL_LOG="/var/log/zbm-install.log"
    exec > >(tee -a "$INSTALL_LOG") 2>&1
    echo "Installation log: $INSTALL_LOG"

    echo "======================================================================"
    echo "Starting Ubuntu 26.04 ZFSBootMenu Installation"
    echo "======================================================================"

    echo ""
    echo "Step 1: Installing prerequisites..."
    apt update
    # curl needed for select_fastest_mirror and chroot downloads
    apt install -y curl debootstrap gdisk zfs-initramfs

    # Select fastest apt mirror now that curl is guaranteed to be available
    select_fastest_mirror

    # Verify ZFS module is loaded or can be loaded
    echo "Verifying ZFS module..."
    if ! lsmod | grep -q "^zfs "; then
        echo "ZFS module not loaded, attempting to load..."
        modprobe zfs || {
            echo "Error: Failed to load ZFS module!"
            echo "ZFS may not be available on this system."
            exit 1
        }
    fi
    if [[ ! -c /dev/zfs ]]; then
        echo "Error: /dev/zfs not found! ZFS is not properly installed."
        exit 1
    fi
    echo "  ✓ ZFS module loaded and /dev/zfs available"

    echo ""
    echo "Step 2: Partitioning disk $DISK..."

    # Check if any partitions on the disk are mounted
    echo "Checking for mounted partitions on $DISK..."
    if lsblk -no MOUNTPOINT "$DISK" 2>/dev/null | grep -qv '^$'; then
        echo "Error: Disk $DISK has mounted partitions!"
        echo "Mounted partitions:"
        lsblk -no NAME,MOUNTPOINT "$DISK"
        echo ""
        echo "Please unmount all partitions before running this script."
        exit 1
    fi
    echo "No mounted partitions found."

    echo "Checking for existing ZFS labels on $DISK..."
    # Match the disk name and its partitions (sda -> sda3, nvme0n1 -> nvme0n1p1)
    # but not a different disk that merely starts the same way (sda vs sdaa)
    if zpool import 2>/dev/null \
        | grep -qE "(^|[^[:alnum:]])$(basename "$DISK")(p?[0-9]+)?([^[:alnum:]]|\$)"; then
        echo "Warning: Disk $DISK appears to be part of an importable ZFS pool!"
        echo "Proceeding will destroy that pool's data."
        echo "Press Ctrl+C within 10 seconds to abort, or wait to continue..."
        sleep 10
    fi

    sgdisk --zap-all "$DISK"
    sgdisk -n1:0:+${EFI_SIZE}M -t1:EF00 "$DISK"     # EFI  (MiB)
    sgdisk -n2:0:+${SWAP_SIZE}M -t2:8200 "$DISK"    # Swap (MiB)
    # rpool takes the whole rest of the disk unless a datapool partition has to
    # be carved out of the same disk (single-disk mode with a datapool)
    if [[ "$DISK_SETUP_MODE" == "separate-disks" || -z "$DATAPOOL_NAME" ]]; then
        sgdisk -n3:0:0 -t3:BF00 "$DISK"             # rpool (all remaining space)
    else
        sgdisk -n3:0:+${RPOOL_SIZE}M -t3:BF00 "$DISK"   # rpool (MiB)
        sgdisk -n4:0:0 -t4:BF00 "$DISK"             # datapool (ZFS partition)
    fi

    # Wait for kernel to update partition table
    partprobe "$DISK"
    udevadm settle

    # Detect partition naming scheme (NVMe uses p1, SATA uses 1)
    if [[ "$DISK" =~ nvme|mmcblk|loop ]]; then
        PART_PREFIX="p"
    else
        PART_PREFIX=""
    fi

    # Set partition variables
    DISK_EFI="${DISK}${PART_PREFIX}1"
    DISK_SWAP="${DISK}${PART_PREFIX}2"
    DISK_RPOOL="${DISK}${PART_PREFIX}3"
    if [[ -n "$DATAPOOL_NAME" && "$DISK_SETUP_MODE" == "single-disk" ]]; then
        DISK_DATAPOOL="${DISK}${PART_PREFIX}4"
    fi

    # Verify all partitions were created successfully (with retry)
    echo "Verifying partitions were created..."
    MAX_RETRIES=5
    RETRY_DELAY=1
    PARTS_TO_CHECK=("$DISK_EFI" "$DISK_SWAP" "$DISK_RPOOL")
    if [[ -n "$DATAPOOL_NAME" && "$DISK_SETUP_MODE" == "single-disk" ]]; then
        PARTS_TO_CHECK+=("$DISK_DATAPOOL")
    fi
    for part in "${PARTS_TO_CHECK[@]}"; do
        retry=0
        while [[ ! -b "$part" ]] && [[ $retry -lt $MAX_RETRIES ]]; do
            echo "  Waiting for $part to appear (attempt $((retry + 1))/$MAX_RETRIES)..."
            sleep $RETRY_DELAY
            udevadm settle
            # NOT ((retry++)) — that returns exit status 1 when retry is 0,
            # which set -e turns into a fatal error on the very first retry
            retry=$(( retry + 1 ))
        done

        if [[ ! -b "$part" ]]; then
            echo "Error: Partition $part was not created after $MAX_RETRIES retries!"
            echo "Partition table:"
            lsblk "$DISK" || true
            sgdisk -p "$DISK" || true
            exit 1
        fi
        echo "  ✓ $part exists"
    done
    echo "All partitions created successfully."

    # Wait for udev to finish creating /dev/disk/by-partuuid/ symlinks before resolving
    udevadm settle

    # Resolve stable by-id paths for ZFS pool creation
    echo "Resolving partition by-id paths..."
    DISK_RPOOL_ID=$(resolve_part_byid "$DISK_RPOOL")
    echo "  rpool:    $DISK_RPOOL_ID"
    if [[ -n "$DATAPOOL_NAME" && "$DISK_SETUP_MODE" == "single-disk" ]]; then
        DISK_DATAPOOL_ID=$(resolve_part_byid "$DISK_DATAPOOL")
        echo "  datapool: $DISK_DATAPOOL_ID"
    fi

    # Stop and mask ALL ZFS live-system services BEFORE touching disks.
    # wipefs/zpool labelclear fire udev events; zed reacts to device changes
    # and can ABRT if it races against pool creation on the same partitions.
    # Also include zfs-mount, zfs-share, zfs-import-bpool which Ubuntu 26.04
    # live ISO may have active in addition to the core import/scan services.
    systemctl stop  zed zfs-zed zfs-import-scan zfs-import-cache zfs-mount zfs-share zfs-import-bpool 2>/dev/null || true
    systemctl mask  zed zfs-zed zfs-import-scan zfs-import-cache zfs-mount zfs-share zfs-import-bpool 2>/dev/null || true
    pkill -x zed 2>/dev/null || true
    sleep 1  # let services fully terminate before udev events from wipefs

    # Limit ZFS ARC on low-RAM systems to prevent OOM during debootstrap.
    # Set before any ZFS operations so the cap is in effect from the start.
    # ZFS ARC defaults to ~50% of RAM; on 2-4GB VMs this leaves too little for debootstrap.
    total_ram_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    if [[ $total_ram_kb -le 4194304 ]]; then
        echo 536870912 > /sys/module/zfs/parameters/zfs_arc_max
        echo "  ZFS ARC capped at 512MB (<=4GB RAM detected)"
    fi

    # Wipe any existing filesystem signatures and ZFS labels
    echo "Clearing filesystem signatures..."
    wipefs -a "$DISK_EFI" 2>/dev/null || true
    wipefs -a "$DISK_SWAP" 2>/dev/null || true
    wipefs -a "$DISK_RPOOL" 2>/dev/null || true
    if [[ -n "$DISK_DATAPOOL" ]]; then
        wipefs -a "$DISK_DATAPOOL" 2>/dev/null || true
    fi

    # Clear any ZFS labels specifically
    zpool labelclear -f "$DISK_RPOOL" 2>/dev/null || true
    if [[ -n "$DISK_DATAPOOL" ]]; then
        zpool labelclear -f "$DISK_DATAPOOL" 2>/dev/null || true
    fi

    echo ""
    echo "Step 3: Creating ZFS root pool..."
    # Create rpool with monolithic structure
    zpool create -f \
        -o ashift=$ASHIFT \
        -o autotrim=on \
        -O acltype=posixacl \
        -O atime=$ZFS_ATIME \
        -O canmount=off \
        -O compression=${COMPRESSION} \
        -O dnodesize=auto \
        -O normalization=formD \
        -O relatime=$ZFS_RELATIME \
        -O xattr=sa \
        -O mountpoint=none \
        rpool "$DISK_RPOOL_ID"

    # Create single monolithic root dataset
    # Parent must be inert (canmount=off, mountpoint=none); only the child boots from /
    zfs create -o canmount=off -o mountpoint=none rpool/ROOT
    zfs create -o canmount=noauto -o mountpoint=/ rpool/ROOT/ubuntu-1

    # Mount root
    zpool export rpool
    zpool import -N -R /mnt rpool
    zfs mount rpool/ROOT/ubuntu-1


    echo ""
    echo "Step 4: Formatting EFI partition..."
    mkfs.vfat -F32 "$DISK_EFI"
    mkdir -p /mnt/boot/efi
    mount "$DISK_EFI" /mnt/boot/efi

    echo ""
    echo "Step 5: Setting up swap..."
    # Swap will be encrypted at boot via crypttab (ephemeral random key per boot)
    # No mkswap needed — cryptsetup will format the swap device on each boot

    # Capture EFI UUID for stable fstab entry (robust against disk renaming)
    DISK_EFI_UUID=$(blkid -s UUID -o value "$DISK_EFI")

    echo ""
    echo "Step 6: Installing Ubuntu base system..."
    debootstrap resolute /mnt "$APT_MIRROR"

    # Verify debootstrap succeeded
    echo "Verifying debootstrap installation..."
    if [[ ! -x /mnt/bin/bash ]]; then
        echo "Error: debootstrap failed! /mnt/bin/bash not found or not executable."
        echo "This usually means network issues or repository problems."
        echo "Contents of /mnt:"
        ls -la /mnt/ || true
        exit 1
    fi
    if [[ ! -d /mnt/usr/bin ]]; then
        echo "Error: debootstrap incomplete! /mnt/usr/bin directory missing."
        exit 1
    fi
    echo "  ✓ debootstrap completed successfully"

    echo ""
    echo "Step 7: Configuring base system..."

    # Copy zpool.cache if it exists
    mkdir -p /mnt/etc/zfs
    if [[ -f /etc/zfs/zpool.cache ]]; then
        cp /etc/zfs/zpool.cache /mnt/etc/zfs/
    else
        echo "Note: /etc/zfs/zpool.cache not found, will be generated on first boot"
    fi

    # Generate fstab (use UUIDs for robustness against disk renaming)
    cat > /mnt/etc/fstab << EOF
# /etc/fstab: static file system information
UUID=$DISK_EFI_UUID  /boot/efi       vfat      defaults    0 1
/dev/mapper/swap     none            swap      defaults    0 0
EOF

    # Configure encrypted swap with a random ephemeral key per boot
    # Use PARTUUID so the entry survives disk enumeration changes across reboots
    SWAP_PARTUUID=$(blkid -s PARTUUID -o value "$DISK_SWAP")
    cat > /mnt/etc/crypttab << EOF
swap  PARTUUID=$SWAP_PARTUUID  /dev/urandom  plain,swap,cipher=aes-xts-plain64:sha256,size=512
EOF

    # Set hostname
    echo "$HOSTNAME" > /mnt/etc/hostname
    cat > /mnt/etc/hosts << EOF
127.0.0.1 localhost
127.0.1.1 $HOSTNAME

# IPv6
::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

    # Configure apt sources (using selected mirror; security always via official
    # archive). Ubuntu 24.04+ uses deb822 in /etc/apt/sources.list.d/ubuntu.sources.
    # Neither file is owned by a package, so both are ours to write.
    mkdir -p /mnt/etc/apt/sources.list.d
    cat > /mnt/etc/apt/sources.list.d/ubuntu.sources << EOF
Types: deb
URIs: $APT_MIRROR
Suites: resolute resolute-updates
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: https://security.ubuntu.com/ubuntu
Suites: resolute-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF

    # debootstrap may also have written the legacy one-line file; leaving both
    # in place makes apt report every suite as "configured multiple times"
    cat > /mnt/etc/apt/sources.list << 'EOF'
# Ubuntu sources are configured in /etc/apt/sources.list.d/ubuntu.sources
# (deb822 format). Do not add entries here — they would duplicate that file.
EOF

    # Configure basic network (DHCP on all interfaces)
    mkdir -p /mnt/etc/netplan
    cat > /mnt/etc/netplan/01-netcfg.yaml << EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    all-en:
      match:
        name: "en*"
      dhcp4: true
      dhcp6: true
    all-eth:
      match:
        name: "eth*"
      dhcp4: true
      dhcp6: true
EOF
    chmod 600 /mnt/etc/netplan/01-netcfg.yaml

    # Set low swappiness to minimize swap usage under normal conditions
    cat > /mnt/etc/sysctl.d/99-swappiness.conf << 'EOF'
# Minimize swap usage - only swap under extreme memory pressure
# Value 1 = minimum (0 means swap only on OOM, which can cause instability)
vm.swappiness=1
EOF

    # Bind mount necessary filesystems
    mount --rbind /dev  /mnt/dev
    mount --rbind /proc /mnt/proc
    mount --rbind /sys  /mnt/sys

    # Copy resolv.conf from live host so chroot apt can resolve DNS
    cp /etc/resolv.conf /mnt/etc/resolv.conf

    echo ""
    echo "Step 8: Installing packages in chroot..."

    # Write APT snapshot cleanup script and systemd units to new system before chroot
    # (written here with quoted heredocs to avoid $ escaping inside the chroot heredoc)
    mkdir -p /mnt/usr/local/bin /mnt/etc/systemd/system
    cat > /mnt/usr/local/bin/cleanup-apt-snapshots.sh << 'EOF'
#!/bin/bash
# Cleanup old APT ZFS snapshots — keeps at most KEEP_COUNT newest

set -euo pipefail

DATASET="rpool/ROOT/ubuntu-1"
SNAPSHOT_PREFIX="apt-"
KEEP_COUNT=10

snapshots=$(zfs list -H -t snapshot -o name -S creation "${DATASET}" | grep "@${SNAPSHOT_PREFIX}[0-9]" || true)

if [[ -z "$snapshots" ]]; then
    total=0
else
    total=$(echo "$snapshots" | wc -l)
fi

echo "Found ${total} APT snapshot(s) on ${DATASET}"
logger -t cleanup-apt-snapshots "Found ${total} APT snapshots on ${DATASET}"

if [[ $total -le $KEEP_COUNT ]]; then
    echo "No cleanup needed (keeping last ${KEEP_COUNT} snapshots)"
    logger -t cleanup-apt-snapshots "No cleanup needed"
    exit 0
fi

to_delete=$((total - KEEP_COUNT))
echo "Deleting ${to_delete} old snapshot(s) (keeping newest ${KEEP_COUNT})..."

to_delete_list=$(echo "$snapshots" | tail -n "$to_delete")

while IFS= read -r snapshot; do
    if [[ -n "$snapshot" ]]; then
        echo "  Deleting: $snapshot"
        zfs destroy "$snapshot"
    fi
done <<< "$to_delete_list"

echo "Cleanup complete!"
logger -t cleanup-apt-snapshots "Cleanup complete: deleted ${to_delete} snapshots"
EOF
    chmod +x /mnt/usr/local/bin/cleanup-apt-snapshots.sh

    cat > /mnt/etc/systemd/system/cleanup-apt-snapshots.service << 'EOF'
[Unit]
Description=Cleanup old APT ZFS snapshots
Documentation=man:zfs(8)

[Service]
Type=oneshot
ExecStart=/usr/local/bin/cleanup-apt-snapshots.sh
StandardOutput=journal
StandardError=journal
EOF

    cat > /mnt/etc/systemd/system/cleanup-apt-snapshots.timer << 'EOF'
[Unit]
Description=Twice-daily cleanup of old APT ZFS snapshots
Documentation=man:zfs(8)

[Timer]
OnCalendar=*-*-* 00:00:00
OnCalendar=*-*-* 12:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

    # Create chroot script with proper variable expansion
    # NOTE: Using unquoted EOF allows variable expansion for $LOCALE, $KEYBOARD_LAYOUT,
    # $KEYBOARD_VARIANT. Use \$ for variables that must be evaluated inside chroot.
    cat > /mnt/tmp/chroot-install.sh << EOF
#!/bin/bash
set -euo pipefail

# Configure keyboard layout (reconfigure deferred until after packages are installed)
cat > /etc/default/keyboard << 'KBEOF'
XKBLAYOUT="$KEYBOARD_LAYOUT"
XKBVARIANT="$KEYBOARD_VARIANT"
XKBOPTIONS=""
BACKSPACE="guess"
KBEOF

# Make transient apt errors fatal so stale package lists don't cause silent
# failures. Install-time scaffolding only — removed at the end of this script so
# the installed system is not left with a hair-trigger `apt update`.
echo 'APT::Update::Error-Mode "any";' > /etc/apt/apt.conf.d/30apt_error_on_transient

# Bootstrap: install ca-certificates and curl first so HTTPS mirrors work.
# Normally the debootstrap-populated lists suffice; fall back to a plain
# apt update (against the pre-bootstrap sources) if they don't.
apt install -y --no-install-recommends ca-certificates curl || {
    apt update
    apt install -y --no-install-recommends ca-certificates curl
}

# Update package lists and upgrade base system using the selected mirror
apt update
apt dist-upgrade -y

# Install remaining packages
apt install -y --no-install-recommends \
    locales \
    linux-generic \
    zfs-initramfs \
    zfsutils-linux \
    zfs-zed \
    cryptsetup \
    openssh-server \
    wget \
    vim \
    htop \
    net-tools \
    iproute2 \
    keyboard-configuration \
    console-setup \
    ubuntu-server \
    pv \
    mbuffer \
    ncdu \
    dkms \
    software-properties-common \
    systemd-timesyncd \
    sanoid

# keyboard-configuration and console-setup are now installed; apply the layout
dpkg-reconfigure -f noninteractive keyboard-configuration

# Set locale (locale-gen/update-locale ship in the locales package installed above)
locale-gen "$LOCALE"
update-locale LANG="$LOCALE"
# Apply console keyboard layout (may not succeed in chroot, non-fatal)
setupcon --force 2>/dev/null || true

# Configure ZFS in initramfs
echo "zfs" >> /etc/initramfs-tools/modules

# Update initramfs (must run after ZFS packages)
update-initramfs -c -k all

# Enable network services
systemctl enable systemd-networkd
systemctl enable systemd-resolved

# Mount /tmp as tmpfs
echo "tmpfs /tmp tmpfs defaults,nosuid,nodev,size=2G 0 0" >> /etc/fstab

# Generate netplan backend config files
netplan generate

# Configure Sanoid for rpool
mkdir -p /etc/sanoid
cat > /etc/sanoid/sanoid.conf << 'SANEOF'
# Sanoid configuration for monolithic rpool

[rpool/ROOT/ubuntu-1]
    use_template = template_production
    recursive = yes

#############################
# Templates
#############################
[template_production]
    frequently = 0
    hourly = 36
    daily = 30
    monthly = 6
    yearly = 0
    autosnap = yes
    autoprune = yes
SANEOF

# APT hook: ZFS snapshot before package upgrades
cat > /etc/apt/apt.conf.d/80-zfs-snapshot << 'HOOKEOF'
// Take ZFS snapshot before package upgrades
DPkg::Pre-Invoke {"if command -v zfs >/dev/null 2>&1; then zfs snapshot rpool/ROOT/ubuntu-1@apt-\$(date +%Y-%m-%d-%H%M%S) || true; fi";};
HOOKEOF

# Enable Sanoid, cleanup timer, and other services
systemctl enable sanoid.timer
systemctl enable cleanup-apt-snapshots.timer
systemctl enable systemd-timesyncd
systemctl enable zfs-zed

# Mask TPM2 setup services — not used by ZFSBootMenu; avoids boot FAILED noise
systemctl mask systemd-tpm2-setup-early.service systemd-tpm2-setup.service

apt install -y zellij

# Drop the install-time strict apt error mode (see top of this script)
rm -f /etc/apt/apt.conf.d/30apt_error_on_transient

# Take initial snapshot
sanoid --take-snapshots --verbose

EOF

    chmod +x /mnt/tmp/chroot-install.sh
    echo "Running package installation in chroot..."
    if ! chroot /mnt /tmp/chroot-install.sh; then
        echo "Error: Package installation in chroot failed!"
        echo "Check the output above for specific errors."
        rm /mnt/tmp/chroot-install.sh
        exit 1
    fi
    rm /mnt/tmp/chroot-install.sh
    echo "  ✓ Package installation completed"

    echo ""
    echo "Step 9: Creating user and setting passwords..."

    # Shell environment → /etc/skel BEFORE useradd so the files are copied
    # into the new home with correct ownership (no host-side chown needed)
    mkdir -p /mnt/etc/skel/.config/zellij
    write_zellij_config /mnt/etc/skel/.config/zellij/config.kdl
    write_bash_aliases /mnt/etc/skel/.bash_aliases
    echo "  ✓ Zellij config and bash aliases staged in /etc/skel"

    # Create user setup script with proper variable expansion
    # NOTE: Using unquoted EOF allows variable expansion (e.g., $USERNAME, $TIMEZONE)
    cat > /mnt/tmp/user-setup.sh << EOF
#!/bin/bash
set -euo pipefail

# Create user with sudo access and standard Ubuntu groups
useradd -m -s /bin/bash -G sudo,adm,cdrom,dip,plugdev "$USERNAME"
echo "User '$USERNAME' created with sudo access."

# Lock root account
passwd -l root
echo "Root account locked. Use 'sudo -i' to get a root shell."

# Configure timezone
ln -sf /usr/share/zoneinfo/"$TIMEZONE" /etc/localtime
echo "$TIMEZONE" > /etc/timezone
dpkg-reconfigure -f noninteractive tzdata

EOF

    chmod +x /mnt/tmp/user-setup.sh
    echo "Running user setup in chroot..."
    if ! chroot /mnt /tmp/user-setup.sh; then
        echo "Error: User setup in chroot failed!"
        echo "Check the output above for specific errors."
        rm /mnt/tmp/user-setup.sh
        exit 1
    fi
    rm /mnt/tmp/user-setup.sh
    # Set password via stdin — never written to disk, safe for all metacharacters
    printf '%s:%s\n' "$USERNAME" "$USER_PASSWORD" | chroot /mnt chpasswd

    # Tabby SFTP integration is handled by _report_cwd in ~/.bash_aliases
    # (staged in /etc/skel above), no per-user file writes needed here
    echo "  ✓ User setup completed"

    echo ""
    echo "Step 10: Installing ZFSBootMenu..."

    # Install ZFSBootMenu from source in chroot with proper variable expansion
    # NOTE: Using unquoted EOF allows variable expansion (e.g., $DISK, $DISK_EFI)
    cat > /mnt/tmp/zbm-install.sh << EOF
#!/bin/bash
set -euo pipefail

# Store disk and partition variables for use in script
DISK="$DISK"
DISK_EFI="$DISK_EFI"

# Install dependencies for ZFSBootMenu compilation
echo "Installing ZFSBootMenu build dependencies..."
apt update
apt install -y --no-install-recommends \\
    bsdextrautils \\
    mbuffer \\
    libsort-versions-perl \\
    libboolean-perl \\
    libyaml-pp-perl \\
    git \\
    fzf \\
    make \\
    kexec-tools \\
    dracut-core \\
    cpio \\
    curl \\
    systemd-boot \\
    binutils \\
    efibootmgr

# Download and compile ZFSBootMenu from source
echo "Downloading ZFSBootMenu from GitHub..."
rm -rf /usr/local/src/zfsbootmenu
mkdir -p /usr/local/src/zfsbootmenu
cd /usr/local/src/zfsbootmenu

# Fetch latest ZFSBootMenu release version dynamically
ZBM_VERSION=\$(curl -s https://api.github.com/repos/zbm-dev/zfsbootmenu/releases/latest \
    | grep -Po '"tag_name": "\Kv[^"]*' || true)
if [[ -z "\$ZBM_VERSION" ]] || [[ ! "\$ZBM_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "  Warning: Could not fetch latest ZBM version, falling back to v2.3.0"
    ZBM_VERSION="v2.3.0"
fi
echo "  - Using ZFSBootMenu version: \$ZBM_VERSION"
git clone --depth 1 --branch "\$ZBM_VERSION" https://github.com/zbm-dev/zfsbootmenu .

# Compile and install ZFSBootMenu
echo "Compiling ZFSBootMenu..."
make core dracut
make install

# Configure ZFSBootMenu
echo "Configuring ZFSBootMenu..."
mkdir -p /etc/zfsbootmenu
# NOTE: Using quoted 'ZBMCONF' prevents variable expansion (literal config file)
cat > /etc/zfsbootmenu/config.yaml << 'ZBMCONF'
Global:
  ManageImages: true
  BootMountPoint: /boot/efi
  Timeout: 10

Components:
  Enabled: false

EFI:
  ImageDir: /boot/efi/EFI/ZBM
  Versions: false
  Enabled: true

Kernel:
  CommandLine: ro quiet loglevel=4 rd.driver.export=zfs
  Prefix: vmlinuz
ZBMCONF

# Generate ZFSBootMenu image
echo "Generating ZFSBootMenu image..."
generate-zbm --debug

# Verify the image was created
if [[ ! -f /boot/efi/EFI/ZBM/vmlinuz.EFI ]]; then
    echo "Error: ZFSBootMenu image not generated!"
    exit 1
fi
echo "ZFSBootMenu image created successfully"

# Create EFI boot entry
echo "Creating EFI boot entry..."
# Extract partition number from DISK_EFI with improved validation
# Handles: /dev/nvme0n1p1 -> 1, /dev/sda1 -> 1, /dev/mmcblk0p1 -> 1
if [[ "\$DISK_EFI" =~ (nvme|mmcblk|loop).*p([0-9]+)$ ]]; then
    # NVMe/MMC style: /dev/nvme0n1p1
    PART_NUM="\${BASH_REMATCH[2]}"
elif [[ "\$DISK_EFI" =~ [a-z]+([0-9]+)$ ]]; then
    # SATA/SAS style: /dev/sda1
    PART_NUM="\${BASH_REMATCH[1]}"
else
    echo "Error: Could not extract partition number from \$DISK_EFI"
    echo "Unexpected device naming format: \$DISK_EFI"
    exit 1
fi

# Validate partition number is reasonable (1-128)
if [[ ! "\$PART_NUM" =~ ^[0-9]+$ ]] || [[ "\$PART_NUM" -lt 1 ]] || [[ "\$PART_NUM" -gt 128 ]]; then
    echo "Error: Invalid partition number: \$PART_NUM"
    echo "Expected a number between 1 and 128"
    exit 1
fi

# Always install to the UEFI fallback path so the system boots even on
# firmware that does not support EFI variables (old systems, CSM, etc.)
echo "Installing ZFSBootMenu to UEFI fallback path..."
mkdir -p /boot/efi/EFI/BOOT
cp /boot/efi/EFI/ZBM/vmlinuz.EFI /boot/efi/EFI/BOOT/BOOTX64.EFI
echo "  ✓ Fallback EFI path set: /EFI/BOOT/BOOTX64.EFI"

# Attempt to create a named EFI boot entry via efibootmgr.
# This requires EFI variable support (efivars/efivarfs) in the firmware.
# On older systems the call may fail; the fallback path above ensures the
# system still boots in that case.
echo "Using disk \$DISK partition \$PART_NUM"
if efibootmgr -c -d "\$DISK" -p "\$PART_NUM" -L "ZFSBootMenu" -l '\EFI\ZBM\vmlinuz.EFI' 2>&1; then
    # Set ZFSBootMenu as first boot priority
    echo "Setting ZFSBootMenu as first boot priority..."
    ZBM_BOOT_NUM=\$(efibootmgr | grep "ZFSBootMenu" | head -1 | sed 's/Boot\([0-9A-F]*\).*/\1/')
    if [[ -n "\$ZBM_BOOT_NUM" ]]; then
        CURRENT_ORDER=\$(efibootmgr | grep "BootOrder:" | sed 's/BootOrder: //')
        NEW_ORDER=\$(echo "\$CURRENT_ORDER" | sed "s/\$ZBM_BOOT_NUM,\?//g" | sed "s/^,//;s/,\$//")
        efibootmgr -o "\$ZBM_BOOT_NUM,\$NEW_ORDER"
        echo "  ✓ ZFSBootMenu set as first boot priority (Boot\$ZBM_BOOT_NUM)"
    else
        echo "WARNING: Could not determine ZFSBootMenu boot entry number"
    fi
else
    echo "WARNING: efibootmgr could not create a boot entry (EFI variables not supported)."
    echo "         The system will boot via the fallback path /EFI/BOOT/BOOTX64.EFI."
    echo "         You may need to select the boot device manually on first boot."
fi

# Create update-zbm wrapper
# NOTE: Using quoted 'WRAPPER_EOF' prevents variable expansion (literal wrapper script)
cat > /usr/local/bin/update-zbm << 'WRAPPER_EOF'
#!/bin/bash
echo "Regenerating ZFSBootMenu..."
generate-zbm --debug
echo "ZFSBootMenu updated successfully"
WRAPPER_EOF
chmod +x /usr/local/bin/update-zbm

# Drop a kernel postinst hook so dpkg triggers ZBM regeneration after every kernel upgrade
mkdir -p /etc/kernel/postinst.d
cat > /etc/kernel/postinst.d/99-update-zbm << 'HOOK_EOF'
#!/bin/sh
set -e
/usr/local/bin/update-zbm
HOOK_EOF
chmod +x /etc/kernel/postinst.d/99-update-zbm

echo "ZFSBootMenu installation complete"

EOF

    chmod +x /mnt/tmp/zbm-install.sh
    echo "Running ZFSBootMenu installation in chroot..."
    if ! chroot /mnt /tmp/zbm-install.sh; then
        echo "Error: ZFSBootMenu installation in chroot failed!"
        echo "Check the output above for specific errors."
        rm /mnt/tmp/zbm-install.sh
        exit 1
    fi
    rm /mnt/tmp/zbm-install.sh
    echo "  ✓ ZFSBootMenu installation completed"

    echo ""
    echo "Step 11: Configuring SSH..."
    chroot /mnt systemctl enable ssh

    # Point /etc/resolv.conf at the systemd-resolved stub. Done from the host
    # AFTER the last chroot that needs DNS (the file copied in Step 7 served
    # them); the symlink target only exists once the new system boots.
    ln -sf /run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf

    echo ""
    echo "Step 12: Setting ZFS properties for boot..."
    zpool set bootfs=rpool/ROOT/ubuntu-1 rpool

    echo ""
    echo "Step 13: Verifying installation..."

    # Verify ZFSBootMenu kernel image exists
    if [[ ! -f /mnt/boot/efi/EFI/ZBM/vmlinuz.EFI ]]; then
        echo "Error: ZFSBootMenu kernel image not found!"
        echo "Expected: /mnt/boot/efi/EFI/ZBM/vmlinuz.EFI"
        exit 1
    fi
    echo "  ✓ ZFSBootMenu kernel image exists"

    # Verify bootfs property is set
    bootfs=$(zpool get -H -o value bootfs rpool)
    if [[ "$bootfs" != "rpool/ROOT/ubuntu-1" ]]; then
        echo "Error: bootfs property not set correctly!"
        exit 1
    fi
    echo "  ✓ bootfs property set correctly"

    # Verify EFI boot entry or fallback path exists
    if [[ -f /mnt/boot/efi/EFI/BOOT/BOOTX64.EFI ]]; then
        echo "  ✓ UEFI fallback path present (/EFI/BOOT/BOOTX64.EFI)"
    elif efibootmgr 2>/dev/null | grep -q "ZFSBootMenu"; then
        echo "  ✓ EFI boot entry created"
    else
        echo "WARNING: Neither fallback EFI path nor efibootmgr entry found. Manual boot setup may be required."
    fi

    # Verify netplan config exists
    if [[ ! -f /mnt/etc/netplan/01-netcfg.yaml ]]; then
        echo "WARNING: Network configuration not found!"
    else
        echo "  ✓ Network configuration exists"
    fi

    echo "Installation verification complete."

    echo ""
    echo "Step 14: Copying installation script for post-reboot..."
    INSTALL_DIR="/mnt/home/$USERNAME/zbm-installer"
    mkdir -p "$INSTALL_DIR"
    cp "$0" "$INSTALL_DIR/"
    chmod 700 "$INSTALL_DIR/$(basename "$0")"

    # Persist installation config so postreboot phase can source it
    cat > "$INSTALL_DIR/zbm-installer.conf" <<EOF
USERNAME="$USERNAME"
DISK="$DISK"
PART_PREFIX="$PART_PREFIX"
DISK_RPOOL_ID="$DISK_RPOOL_ID"
DISK_DATAPOOL_ID="$DISK_DATAPOOL_ID"
DATAPOOL_NAME="$DATAPOOL_NAME"
DATAPOOL_MOUNTPOINT="$DATAPOOL_MOUNTPOINT"
DISK_SETUP_MODE="$DISK_SETUP_MODE"
KEYBOARD_LAYOUT="$KEYBOARD_LAYOUT"
KEYBOARD_VARIANT="$KEYBOARD_VARIANT"
POSTREBOOT_DONE="n"
EOF
    chmod 600 "$INSTALL_DIR/zbm-installer.conf"
    TARGET_UID=$(awk -F: -v user="$USERNAME" '$1==user {print $3}' /mnt/etc/passwd)
    TARGET_GID=$(awk -F: -v user="$USERNAME" '$1==user {print $4}' /mnt/etc/passwd)
    chown -R "$TARGET_UID:$TARGET_GID" "$INSTALL_DIR"
    echo "  ✓ Installation script and config saved to ~/zbm-installer/"

    # Copy install log into new system so it survives after reboot
    mkdir -p /mnt/var/log 2>/dev/null || true
    cp "$INSTALL_LOG" /mnt/var/log/zbm-install.log 2>/dev/null || true

    echo ""
    echo "Step 15: Unmounting and exporting pool..."

    # Kill any processes still using /mnt to prevent busy-mount failures
    fuser -km /mnt 2>/dev/null || true

    # Prevent unmount propagation back to live host
    mount --make-rslave /mnt/dev  2>/dev/null || true
    mount --make-rslave /mnt/proc 2>/dev/null || true
    mount --make-rslave /mnt/sys  2>/dev/null || true

    # Unmount in specific order to handle busy mounts
    # Some mounts like cgroup may be busy, so we use lazy unmount as fallback
    if ! umount -R /mnt 2>/dev/null; then
        echo "  Note: Some mounts were busy, using lazy unmount..."
        umount -l /mnt/sys/fs/cgroup 2>/dev/null || true
        umount -l /mnt/dev 2>/dev/null || true
        umount -l /mnt/proc 2>/dev/null || true
        umount -l /mnt/sys 2>/dev/null || true
        umount /mnt/boot/efi 2>/dev/null || true
        umount /mnt 2>/dev/null || true
    fi

    # Explicitly release ZFS datasets before exporting, then sync to flush I/O
    zfs unmount -a 2>/dev/null || true
    sync

    if ! zpool export rpool 2>/dev/null; then
        echo "  Note: Normal export failed, retrying with force flag..."
        if ! zpool export -f rpool 2>/dev/null; then
            echo "  Warning: Pool export failed — pool will be recovered on next import."
        fi
    fi

    echo ""
    echo "======================================================================"
    echo "Initial installation complete!"
    echo "======================================================================"
    echo ""
    echo "IMPORTANT:"
    echo "  - User: $USERNAME (sudo enabled)"
    echo "  - Root account is LOCKED. Use 'sudo -i' for a root shell."
    echo ""
    echo "Next steps:"
    echo "  1. Remove the USB drive"
    echo "  2. Reboot the system"
    echo "  3. Login as $USERNAME"
    echo "  4. Run: sudo ~/zbm-installer/$(basename "$0")"
    echo "     (mode is auto-detected; the 'postreboot' argument still works)"
    echo ""
    echo "Postreboot will:"
    echo "  - Set up Sanoid snapshot schedules"
    if [[ -n "$DATAPOOL_NAME" ]]; then
        if [[ "$DISK_SETUP_MODE" == "separate-disks" ]]; then
            echo "  - Ask which disk(s) to use for the datapool ($DATAPOOL_NAME)"
            echo "    and create the pool (single / mirror / raidz)"
        else
            echo "  - Create the datapool ($DATAPOOL_NAME) on partition 4 of $DISK"
        fi
    fi
    echo "  - Ask about optional software (Docker, KVM/libvirt) and install it"
    echo ""
    echo "Reboot now? (y/n)"
    read -r response
    if [[ "$response" == "y" ]]; then
        reboot
    fi

################################################################################
# POST-REBOOT SETUP
################################################################################
elif [[ "$MODE" == "postreboot" ]]; then
    echo "======================================================================"
    echo "Post-reboot setup - Installing Sanoid and configuring snapshots"
    echo "======================================================================"

    # Verify we're running as root
    if [[ $EUID -ne 0 ]]; then
        echo "This script must be run as root"
        exit 1
    fi

    # Log everything — this phase installs Docker/libvirt and creates pools, so
    # a failure needs to be diagnosable after the terminal is gone.
    # Started after the root check so a non-root run cannot fail on the log file.
    POSTREBOOT_LOG="/var/log/zbm-postreboot.log"
    exec > >(tee -a "$POSTREBOOT_LOG") 2>&1
    echo "Post-reboot log: $POSTREBOOT_LOG"

    # All questions are asked by prompt_postreboot_software(); no package may
    # open a debconf dialog in the middle of the unattended installation steps
    export DEBIAN_FRONTEND=noninteractive

    # Load persisted installation config from initial phase (co-located with this script)
    INSTALL_CONF="$(dirname "$0")/zbm-installer.conf"
    if [[ -f "$INSTALL_CONF" ]]; then
        # shellcheck source=/dev/null
        source "$INSTALL_CONF"
        echo "  ✓ Loaded installation config from $INSTALL_CONF"
        # The conf does not carry HOSTNAME — take it from the running system so
        # mail senders and printed URLs show the real name, not the default
        HOSTNAME="$(hostname)"
    else
        echo "Error: $INSTALL_CONF not found."
        echo "postreboot must run from the installer directory created during install:"
        echo "  sudo ~/zbm-installer/$(basename "$0") postreboot"
        exit 1
    fi

    validate_inputs
    echo "Configuration validated successfully."

    echo ""
    echo "Step 0: Checking network connectivity..."
    if ! ping -c 1 -W 5 1.1.1.1 >/dev/null 2>&1 && ! ping -c 1 -W 5 9.9.9.9 >/dev/null 2>&1; then
        # ICMP may be blocked; try HTTPS as fallback
        if ! curl -s --max-time 10 -o /dev/null https://archive.ubuntu.com; then
            echo "Error: No network connectivity detected (tested ICMP and HTTPS)!"
            echo "Please check your network connection and try again."
            exit 1
        fi
        echo "  ✓ Network connectivity verified (HTTPS - ICMP blocked)"
    else
        echo "  ✓ Network connectivity verified"
    fi

    # Flipped to 1 once the datapool is fully created/imported and configured.
    # Until then a failure leaves a half-built pool that is better exported;
    # afterwards exporting would drop it from /etc/zfs/zpool.cache, so a later
    # unrelated failure (apt, docker, libvirt) would silently cost the user
    # their pool on the next boot.
    DATAPOOL_READY=0

    # Set up error handling for postreboot mode
    cleanup_postreboot() {
        echo ""
        echo "======================================================================"
        echo "Error: Post-reboot setup failed!"
        echo "======================================================================"

        # Try to export the datapool only if it was left partially created
        if [[ -n "${DATAPOOL_NAME:-}" ]] && [[ "${DATAPOOL_READY:-0}" -eq 0 ]]; then
            zpool export "$DATAPOOL_NAME" 2>/dev/null || true
        elif [[ -n "${DATAPOOL_NAME:-}" ]]; then
            echo "Datapool '$DATAPOOL_NAME' is intact and stays imported."
        fi

        echo "The system is bootable but snapshot management may not be configured."
        echo "Please check the errors above and fix manually or re-run this script."
    }
    trap cleanup_postreboot ERR

    echo ""
    echo "Step 1: Starting snapshot timers..."
    systemctl enable --now sanoid.timer
    systemctl enable --now cleanup-apt-snapshots.timer
    echo "  ✓ Sanoid and cleanup timers active"

    # Optional: Create (or import) datapool if configured
    if [[ -n "$DATAPOOL_NAME" ]]; then
        echo ""
        echo "Step 2: Setting up datapool '$DATAPOOL_NAME'..."

        # A re-run finds the pool already imported. Neither branch below can
        # cope with that: offer_datapool_import() only lists *importable* pools
        # (so it returns 1), and the topology menu would then ask which disks to
        # build a pool that already exists from — or, with no free disks left,
        # push the "continue without a datapool" prompt that drops the Sanoid
        # section for it.
        if zpool list "$DATAPOOL_NAME" &>/dev/null; then
            echo "  ✓ Datapool '$DATAPOOL_NAME' is already imported — skipping selection"
            _mp=$(zfs get -H -o value mountpoint "$DATAPOOL_NAME")
            if [[ "$_mp" == /* ]] && [[ "$_mp" != "$DATAPOOL_MOUNTPOINT" ]]; then
                echo "  - Mountpoint is $_mp (conf said ${DATAPOOL_MOUNTPOINT:-unset})"
                DATAPOOL_MOUNTPOINT="$_mp"
                persist_conf_var DATAPOOL_MOUNTPOINT "$DATAPOOL_MOUNTPOINT"
            fi
        # Otherwise offer importing an existing pool first. On import
        # DATAPOOL_NAME and DATAPOOL_MOUNTPOINT are taken from the imported pool
        # and the creation block below skips via its zpool-list check.
        elif offer_datapool_import; then
            # Persist the (possibly different) pool name/mountpoint so re-runs
            # of postreboot find the imported pool instead of trying to create
            persist_conf_var DATAPOOL_NAME "$DATAPOOL_NAME"
            persist_conf_var DATAPOOL_MOUNTPOINT "$DATAPOOL_MOUNTPOINT"
        # Select topology interactively; sets DATAPOOL_TOPOLOGY and DATAPOOL_DISK_IDS.
        # Returns 1 when no suitable extra disks exist (separate-disks mode).
        elif ! select_datapool_topology_and_disks; then
            read -rp "Continue without a datapool (software datasets will go on rpool)? [y/N]: " _ans
            if [[ ! "$_ans" =~ ^[Yy]$ ]]; then
                echo "Aborting. Attach the datapool disk(s) and re-run postreboot."
                exit 1
            fi
            DATAPOOL_NAME=""    # skip pool creation this run; conf keeps the name
        fi
    fi

    if [[ -n "$DATAPOOL_NAME" ]]; then
        # Properties the datapool gets on creation, mirroring rpool (Step 3 of
        # the initial phase) so a datapool is not the poor relation:
        #   autotrim    — SSDs stay fast; a no-op on spinning disks
        #   acltype/xattr — required by Docker's overlay2 and cheap everywhere
        #                   else; set here so every child dataset inherits them
        #   dnodesize   — matches xattr=sa
        # normalization=formD is deliberately NOT copied from rpool: it implies
        # utf8only=on, which would reject filenames that Samba/NFS clients are
        # allowed to create. These are creation-time defaults only — an existing
        # pool that gets imported is left exactly as the user made it.
        DATAPOOL_PROPS=(
            -o autotrim=on
            -O compression="${COMPRESSION}"
            -O atime="$ZFS_ATIME"
            -O relatime="$ZFS_RELATIME"
            -O acltype=posixacl
            -O xattr=sa
            -O dnodesize=auto
        )

        # Create mount point
        echo "  - Creating mount point: $DATAPOOL_MOUNTPOINT"
        mkdir -p "$DATAPOOL_MOUNTPOINT"

        # Create the pool (idempotent: skip if already imported — including
        # pools just imported via offer_datapool_import)
        if zpool list "$DATAPOOL_NAME" &>/dev/null; then
            echo "  ✓ Datapool '$DATAPOOL_NAME' already imported, skipping creation"
        elif [[ "$DATAPOOL_TOPOLOGY" == "single" ]]; then
            echo "  - Creating ZFS pool: $DATAPOOL_NAME (single)"
            if [[ "$DISK_SETUP_MODE" == "separate-disks" ]]; then
                # Separate mode: "single" means 1 whole disk selected interactively
                DISK_DATAPOOL_ID="${DATAPOOL_DISK_IDS[0]}"
                echo "  - Using whole disk: $DISK_DATAPOOL_ID"
                if [[ ! -b "$DISK_DATAPOOL_ID" ]]; then
                    echo "Error: Disk path not found: $DISK_DATAPOOL_ID"
                    exit 1
                fi
                confirm_labelclear "$DISK_DATAPOOL_ID"
                zpool create -f -o ashift=$ASHIFT \
                             "${DATAPOOL_PROPS[@]}" \
                             -O mountpoint="$DATAPOOL_MOUNTPOINT" \
                             "$DATAPOOL_NAME" "$DISK_DATAPOOL_ID"
                echo "  ✓ Datapool '$DATAPOOL_NAME' (single whole disk) created at $DATAPOOL_MOUNTPOINT"
            else
                # Single-disk mode: use partition 4 of the install disk (original behaviour)
                if [[ "$DISK" =~ nvme|mmcblk|loop ]]; then PART_PREFIX="p"; else PART_PREFIX=""; fi
                DATAPOOL_PARTITION="${DISK}${PART_PREFIX}4"
                if [[ ! -b "$DATAPOOL_PARTITION" ]]; then
                    echo "Error: Datapool partition $DATAPOOL_PARTITION not found!"
                    lsblk "$DISK" || true
                    exit 1
                fi
                DISK_DATAPOOL_ID=$(resolve_part_byid "$DATAPOOL_PARTITION")
                echo "  - Using partition: $DISK_DATAPOOL_ID"
                zpool create -f -o ashift=$ASHIFT \
                             "${DATAPOOL_PROPS[@]}" \
                             -O mountpoint="$DATAPOOL_MOUNTPOINT" \
                             "$DATAPOOL_NAME" "$DISK_DATAPOOL_ID"
                echo "  ✓ Datapool '$DATAPOOL_NAME' (single) created at $DATAPOOL_MOUNTPOINT"
            fi
        else
            # Multi-disk topology: use whole disks selected interactively
            echo "  - Creating ZFS pool: $DATAPOOL_NAME ($DATAPOOL_TOPOLOGY)"
            echo "  - Disks: ${DATAPOOL_DISK_IDS[*]}"

            # Validate each resolved path is a block device
            for _id in "${DATAPOOL_DISK_IDS[@]}"; do
                if [[ ! -b "$_id" ]]; then
                    echo "Error: Disk path not found: $_id"
                    exit 1
                fi
            done

            # Check for existing ZFS labels that would be destroyed by -f
            # (zpool import -d <device> requires modern OpenZFS — fine on 26.04)
            confirm_labelclear "${DATAPOOL_DISK_IDS[@]}"

            zpool create -f -o ashift=$ASHIFT \
                         "${DATAPOOL_PROPS[@]}" \
                         -O mountpoint="$DATAPOOL_MOUNTPOINT" \
                         "$DATAPOOL_NAME" "$DATAPOOL_TOPOLOGY" "${DATAPOOL_DISK_IDS[@]}"
            echo "  ✓ Datapool '$DATAPOOL_NAME' ($DATAPOOL_TOPOLOGY) created at $DATAPOOL_MOUNTPOINT"
        fi

        # Add to Sanoid config (idempotent: skip if section already present)
        echo ""
        if ! grep -q "^\[$DATAPOOL_NAME\]" /etc/sanoid/sanoid.conf; then
            echo "  - Adding datapool to Sanoid configuration..."
            cat >> /etc/sanoid/sanoid.conf << EOF

[$DATAPOOL_NAME]
    use_template = template_production
    recursive = yes
EOF
            echo "  ✓ Sanoid configured for $DATAPOOL_NAME"
        else
            echo "  ✓ Sanoid already configured for $DATAPOOL_NAME, skipping"
        fi

        DATAPOOL_READY=1

    else
        echo ""
        echo "Step 2: Skipping datapool creation (DATAPOOL_NAME not set)"
    fi

    echo ""
    echo "Step 3: Optional software selection..."
    prompt_postreboot_software

    # Storage target for software datasets: single data pool → used directly,
    # several pools → user chooses, none → rpool fallback
    STORAGE_POOL="rpool"
    STORAGE_BASE=""

    if [[ "$INSTALL_DOCKER" == "y" || "$INSTALL_VIRT" == "y" ]]; then
        select_storage_pool
        echo ""
        echo "Step 4: Creating software datasets on $STORAGE_POOL..."
        create_software_datasets "$STORAGE_POOL" "$STORAGE_BASE"

        # User-writable data areas; dockerroot and VM image storage stay
        # root-owned (managed by dockerd/libvirtd)
        if [[ "$STORAGE_POOL" != "rpool" ]]; then
            chown "$USERNAME:$USERNAME" "$STORAGE_BASE"
        fi
        if [[ "$INSTALL_DOCKER" == "y" ]]; then
            chown "$USERNAME:$USERNAME" \
                "$STORAGE_BASE/docker" \
                "$STORAGE_BASE/docker/storage" \
                "$STORAGE_BASE/docker/stack"
        fi
    fi

    if [[ "$INSTALL_DOCKER" == "y" ]]; then
        echo ""
        echo "Step 5: Installing Docker Engine..."
        install_docker_postreboot
    fi

    if [[ "$INSTALL_VIRT" == "y" ]]; then
        echo ""
        echo "Step 6: Installing KVM/libvirt virtualization..."
        install_virtualization_postreboot
    fi

    if [[ "$INSTALL_PODMAN" == "y" ]]; then
        echo ""
        echo "Step 7: Installing Podman..."
        install_podman_postreboot
    fi

    # Mail relay first — smartd, ZED, fail2ban and unattended-upgrades all hand
    # their alerts to /usr/sbin/sendmail, which only exists once msmtp-mta is in
    if [[ "$INSTALL_MTA" == "y" ]]; then
        echo ""
        echo "Step 8: Configuring mail relay (msmtp)..."
        install_mta_postreboot
    fi

    if [[ "$INSTALL_HEALTH" == "y" ]]; then
        echo ""
        echo "Step 9: Setting up disk and pool health monitoring..."
        install_health_postreboot
    fi

    if [[ "$INSTALL_UNATTENDED" == "y" ]]; then
        echo ""
        echo "Step 10: Enabling unattended security upgrades..."
        install_unattended_upgrades_postreboot
    fi

    if [[ "$INSTALL_TAILSCALE" == "y" ]]; then
        echo ""
        echo "Step 11: Installing Tailscale..."
        install_tailscale_postreboot
    fi

    if [[ "$INSTALL_COCKPIT" == "y" ]]; then
        echo ""
        echo "Step 12: Installing Cockpit..."
        install_cockpit_postreboot
    fi

    if [[ "$INSTALL_SAMBA" == "y" ]]; then
        echo ""
        echo "Step 13: Installing Samba..."
        install_samba_postreboot
    fi

    if [[ "$INSTALL_NFS" == "y" ]]; then
        echo ""
        echo "Step 14: Installing NFS server..."
        install_nfs_postreboot
    fi

    if [[ "$INSTALL_NODEEXP" == "y" ]]; then
        echo ""
        echo "Step 15: Installing prometheus-node-exporter..."
        install_nodeexp_postreboot
    fi

    if [[ "$INSTALL_NETDATA" == "y" ]]; then
        echo ""
        echo "Step 16: Installing netdata..."
        install_netdata_postreboot
    fi

    if [[ "$INSTALL_NUT" == "y" ]]; then
        echo ""
        echo "Step 17: Installing UPS monitoring (NUT)..."
        install_nut_postreboot
    fi

    if [[ "$INSTALL_TOOLBELT" == "y" ]]; then
        echo ""
        echo "Step 18: Installing shell toolbelt..."
        install_toolbelt_postreboot
    fi

    # Hardening runs last: SSH first (so a broken config is caught while the
    # session is still open), then fail2ban, then the firewall that both depend on
    if [[ "$HARDEN_SSH" == "y" ]]; then
        echo ""
        echo "Step 19: Hardening SSH..."
        harden_ssh_postreboot
    fi

    if [[ "$INSTALL_FAIL2BAN" == "y" ]]; then
        echo ""
        echo "Step 20: Installing fail2ban..."
        install_fail2ban_postreboot
    fi

    if [[ "$INSTALL_UFW" == "y" ]]; then
        echo ""
        echo "Step 21: Enabling the ufw host firewall..."
        install_ufw_postreboot
    fi

    # Written only after everything above succeeded, so a failed run keeps
    # mode auto-detection pointing at postreboot for a re-run
    echo ""
    echo "Step 22: Recording postreboot completion..."
    persist_postreboot_selection
    if grep -q '^POSTREBOOT_DONE=' "$INSTALL_CONF"; then
        sed -i 's/^POSTREBOOT_DONE=.*/POSTREBOOT_DONE="y"/' "$INSTALL_CONF"
    else
        echo 'POSTREBOOT_DONE="y"' >> "$INSTALL_CONF"
    fi
    echo "  ✓ Completion marker written to $INSTALL_CONF"

    echo ""
    echo "======================================================================"
    echo "Post-reboot setup complete!"
    echo "======================================================================"
    echo ""
    echo "Your system is now ready. Summary:"
    echo ""
    echo "  - Monolithic rpool: rpool/ROOT/ubuntu-1"
    if [[ -n "$DATAPOOL_NAME" ]]; then
        echo "  - Datapool '$DATAPOOL_NAME' created and mounted at $DATAPOOL_MOUNTPOINT"
    else
        echo "  - No datapool configured (system-only install)"
    fi
    echo "  - Sanoid configured for hourly/daily/monthly snapshots"
    echo "  - APT hook creates snapshots before updates (keeps last 10, cleaned weekly)"
    echo "  - ZFSBootMenu installed and configured"
    echo ""
    echo "Next steps:"
    echo "  - Use 'passwd' to change your password if needed"
    if [[ "$INSTALL_DOCKER" == "y" ]]; then
        echo "  - Docker datasets created automatically:"
        echo "      $STORAGE_POOL/docker/dockerroot  ← Docker data-root (images, containers)"
        echo "      $STORAGE_POOL/docker/storage     ← External container data"
        echo "      $STORAGE_POOL/docker/stack       ← Docker Compose project files"
    elif [[ -n "$DATAPOOL_NAME" ]]; then
        echo "  - Create datasets in $DATAPOOL_NAME as needed (e.g. zfs create $DATAPOOL_NAME/data)"
    fi
    if [[ "$INSTALL_VIRT" == "y" ]]; then
        echo "  - libvirt 'default' storage pool: $VIRT_STORAGE_DIR"
        echo "    Connect remotely with virt-manager via qemu+ssh://$USERNAME@<this-host>/system"
    fi
    if [[ "$INSTALL_DOCKER" == "y" || "$INSTALL_VIRT" == "y" ]]; then
        echo "  - Re-login (or reboot) so docker/libvirt group membership takes effect"
    fi
    if [[ "$INSTALL_HEALTH" == "y" ]]; then
        echo "  - Health monitoring: smartd + ZED alerts → $ADMIN_EMAIL, monthly scrub timers"
        echo "    Check with: smartctl -a /dev/<disk> | systemctl list-timers 'zfs-scrub*'"
    fi
    if [[ "$INSTALL_MTA" == "y" ]]; then
        echo "  - Mail relay: $SMTP_HOST:$SMTP_PORT (credentials in /etc/msmtprc, mode 600)"
        echo "    Send a test: echo test | mail -s 'zbm test' $ADMIN_EMAIL"
    elif [[ "$INSTALL_HEALTH" == "y" || "$INSTALL_UNATTENDED" == "y" ]]; then
        echo "  - No MTA configured — alert mail stays in the local root mailbox"
    fi
    if [[ "$INSTALL_UNATTENDED" == "y" ]]; then
        echo "  - Unattended security upgrades on (no auto-reboot); each run is snapshotted"
        echo "    Dry run: unattended-upgrade --dry-run --debug"
    fi
    if [[ "$INSTALL_TAILSCALE" == "y" ]]; then
        if [[ -n "$TAILSCALE_AUTHKEY" ]]; then
            echo "  - Tailscale connected — check with: tailscale status"
        else
            echo "  - Tailscale installed — join the tailnet with: sudo tailscale up --ssh"
        fi
    fi
    if [[ "$HARDEN_SSH" == "y" ]]; then
        echo "  - SSH hardening in /etc/ssh/sshd_config.d/10-zbm-hardening.conf"
        if [[ "$HARDEN_SSH_FORCE" != "y" ]]; then
            echo "    Password login is still enabled — copy a key in, then set PasswordAuthentication no"
        fi
    fi
    if [[ "$INSTALL_UFW" == "y" ]]; then
        echo "  - ufw active: ufw status verbose"
    fi
    if [[ "$INSTALL_FAIL2BAN" == "y" ]]; then
        echo "  - fail2ban active: fail2ban-client status sshd"
    fi
    if [[ "$INSTALL_COCKPIT" == "y" ]]; then
        echo "  - Cockpit: https://$HOSTNAME:9090"
    fi
    if [[ "$INSTALL_NETDATA" == "y" ]]; then
        echo "  - netdata: http://$HOSTNAME:19999"
    fi
    if [[ "$INSTALL_NODEEXP" == "y" ]]; then
        echo "  - node-exporter metrics: http://$HOSTNAME:9100/metrics"
    fi
    if [[ "$INSTALL_NUT" == "y" ]]; then
        echo "  - NUT installed but not yet bound to a UPS — see the notes above"
    fi
    if [[ "$INSTALL_SAMBA" == "y" ]]; then
        echo "  - Samba installed; add the user with: smbpasswd -a $USERNAME"
    fi
    if [[ "$INSTALL_NFS" == "y" ]]; then
        echo "  - NFS server installed; export with: zfs set sharenfs=... <dataset>"
    fi
    echo "  - Re-run this script with no argument any time to update ZFSBootMenu"
    echo ""
    echo "Snapshot management:"
    echo "  - View snapshots: zfs list -t snapshot"
    echo "  - Manual snapshot: zfs snapshot rpool/ROOT/ubuntu-1@manual"
    echo "  - Rollback: reboot -> ZFSBootMenu -> select snapshot -> Ctrl+X"
    echo ""
    echo "For syncoid backups to another machine:"
    echo "  syncoid rpool/ROOT/ubuntu-1 backup-server:backup/rpool"
    echo ""

################################################################################
# REINSTALL / UPDATE ZFSBOOTMENU (Run on installed system)
################################################################################
elif [[ "$MODE" == "reinstall-zbm" ]]; then
    echo "======================================================================"
    echo "Reinstalling / updating ZFSBootMenu"
    echo "======================================================================"

    # Verify we're running as root
    if [[ $EUID -ne 0 ]]; then
        echo "This script must be run as root"
        exit 1
    fi

    # Verify EFI partition is mounted (sanity check: we're on the installed system)
    if ! mountpoint -q /boot/efi 2>/dev/null; then
        echo "Error: /boot/efi is not mounted."
        echo "Mount it first: mount \$(findmnt -n -o SOURCE /boot/efi) /boot/efi"
        exit 1
    fi

    echo ""
    echo "Step 1: Checking network connectivity..."
    if ! ping -c 1 -W 5 1.1.1.1 >/dev/null 2>&1 && ! ping -c 1 -W 5 9.9.9.9 >/dev/null 2>&1; then
        if ! curl -s --max-time 10 -o /dev/null https://api.github.com; then
            echo "Error: No network connectivity detected."
            exit 1
        fi
        echo "  ✓ Network connectivity verified (HTTPS - ICMP blocked)"
    else
        echo "  ✓ Network connectivity verified"
    fi

    echo ""
    echo "Step 2: Fetching latest ZFSBootMenu release..."
    ZBM_VERSION=$(curl -s https://api.github.com/repos/zbm-dev/zfsbootmenu/releases/latest \
        | grep -Po '"tag_name": "\Kv[^"]*' || true)
    if [[ -z "$ZBM_VERSION" ]] || [[ ! "$ZBM_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "  Warning: Could not fetch latest ZBM version, falling back to v2.3.0"
        ZBM_VERSION="v2.3.0"
    fi
    echo "  - Target version: $ZBM_VERSION"

    echo ""
    echo "Step 3: Installing ZFSBootMenu build dependencies..."
    apt update
    apt install -y --no-install-recommends \
        bsdextrautils \
        mbuffer \
        libsort-versions-perl \
        libboolean-perl \
        libyaml-pp-perl \
        git \
        fzf \
        make \
        kexec-tools \
        dracut-core \
        cpio \
        curl \
        systemd-boot \
        binutils \
        efibootmgr

    echo ""
    echo "Step 4: Cloning ZFSBootMenu $ZBM_VERSION..."
    ZBM_SRC="/usr/local/src/zfsbootmenu"
    # Back up existing source if present
    if [[ -d "$ZBM_SRC" ]]; then
        mv "$ZBM_SRC" "${ZBM_SRC}.bak.$(date +%Y%m%d-%H%M%S)"
        echo "  - Backed up existing source dir"
    fi

    # Keep only the 2 newest backups — the timestamp suffix sorts chronologically
    mapfile -t _old_baks < <(find "$(dirname "$ZBM_SRC")" -maxdepth 1 -type d \
        -name "$(basename "$ZBM_SRC").bak.*" 2>/dev/null | sort -r | tail -n +3)
    for _bak in ${_old_baks[@]+"${_old_baks[@]}"}; do
        rm -rf "$_bak"
        echo "  - Removed old backup: $_bak"
    done
    mkdir -p "$ZBM_SRC"
    git clone --depth 1 --branch "$ZBM_VERSION" https://github.com/zbm-dev/zfsbootmenu "$ZBM_SRC"
    cd "$ZBM_SRC"

    echo ""
    echo "Step 5: Compiling and installing ZFSBootMenu..."
    make core dracut
    make install

    echo ""
    echo "Step 6: Regenerating ZFSBootMenu image..."
    generate-zbm --debug

    # Verify image was created
    if [[ ! -f /boot/efi/EFI/ZBM/vmlinuz.EFI ]]; then
        echo "Error: ZFSBootMenu image not found after generation!"
        exit 1
    fi

    # Update UEFI fallback path
    mkdir -p /boot/efi/EFI/BOOT
    cp /boot/efi/EFI/ZBM/vmlinuz.EFI /boot/efi/EFI/BOOT/BOOTX64.EFI
    echo "  ✓ Fallback EFI path updated: /EFI/BOOT/BOOTX64.EFI"

    echo ""
    echo "======================================================================"
    echo "ZFSBootMenu $ZBM_VERSION installed successfully!"
    echo "======================================================================"
    echo ""
    echo "Run 'update-zbm' at any time to regenerate the boot image."
    echo ""

else
    echo "Invalid mode: $MODE"
    echo "Usage: $0 [initial|postreboot|reinstall-zbm]  (no argument = auto-detect)"
    exit 1
fi
