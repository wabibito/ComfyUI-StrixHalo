#!/usr/bin/env bash
#
# setup-kernel-ubuntu.sh
# Guided editor for the Strix Halo unified-memory kernel parameters on Ubuntu.
#
# It appends/updates three parameters in GRUB_CMDLINE_LINUX_DEFAULT:
#     amd_iommu=off
#     amdgpu.gttsize=<MiB>        (GTT window — how much system RAM the iGPU may use)
#     ttm.pages_limit=<pages>     (TTM page pool cap; pages = gttsize_MiB * 256)
#
# Equivalent to the Fedora project's GRUB_CMDLINE_LINUX edit, adapted for Ubuntu's
# GRUB_CMDLINE_LINUX_DEFAULT, with a backup, a dry-run preview, and a size chosen
# from your installed RAM. You apply by rebooting after the script finishes.
#
# Usage:
#   ./setup-kernel-ubuntu.sh                 # auto-size from RAM, interactive confirm
#   ./setup-kernel-ubuntu.sh --gtt-gib 124   # force a specific GTT size in GiB
#   ./setup-kernel-ubuntu.sh --dry-run       # show changes, write nothing
#   ./setup-kernel-ubuntu.sh --yes           # skip the confirmation prompt

set -euo pipefail

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }

GRUB_FILE="/etc/default/grub"
DRY_RUN=0
ASSUME_YES=0
FORCE_GTT_GIB=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --yes|-y)  ASSUME_YES=1; shift ;;
        --gtt-gib) FORCE_GTT_GIB="${2:?--gtt-gib needs a value}"; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) err "Unknown argument: $1"; exit 1 ;;
    esac
done

[[ -f "$GRUB_FILE" ]] || { err "$GRUB_FILE not found. Is this a GRUB-based Ubuntu install?"; exit 1; }

# ----------------------------------------------------------------------------
# 1. Determine GTT size.
#    Reserve ~4 GiB for the OS; the rest becomes the iGPU GTT window.
#    gttsize is in MiB. ttm.pages_limit is in 4 KiB pages = MiB * 256.
# ----------------------------------------------------------------------------
total_kib="$(awk '/^MemTotal:/{print $2}' /proc/meminfo)"
total_gib=$(( total_kib / 1024 / 1024 ))
log "Detected ${total_gib} GiB total RAM."

if [[ -n "$FORCE_GTT_GIB" ]]; then
    gtt_gib="$FORCE_GTT_GIB"
    log "Using forced GTT size: ${gtt_gib} GiB"
else
    # Reserve 4 GiB for the OS, like the upstream Fedora 128 GiB → 124 GiB default.
    gtt_gib=$(( total_gib - 4 ))
    (( gtt_gib < 8 )) && gtt_gib=8
    log "Auto-sized GTT: ${gtt_gib} GiB (reserving 4 GiB for the OS)."
fi

gtt_mib=$(( gtt_gib * 1024 ))
ttm_pages=$(( gtt_mib * 256 ))

NEW_PARAMS=( "amd_iommu=off" "amdgpu.gttsize=${gtt_mib}" "ttm.pages_limit=${ttm_pages}" )
log "Will set: ${NEW_PARAMS[*]}"

# ----------------------------------------------------------------------------
# 2. Read current GRUB_CMDLINE_LINUX_DEFAULT, strip any prior copies of our
#    three keys, and append the new values.
# ----------------------------------------------------------------------------
current_line="$(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE" || true)"
if [[ -z "$current_line" ]]; then
    warn "No GRUB_CMDLINE_LINUX_DEFAULT line found; a new one will be created."
    current_value=""
else
    # Strip the GRUB_CMDLINE_LINUX_DEFAULT=" ... " wrapper.
    current_value="${current_line#GRUB_CMDLINE_LINUX_DEFAULT=}"
    current_value="${current_value%\"}"
    current_value="${current_value#\"}"
fi

# Remove any existing instances of the keys we manage.
cleaned="$current_value"
for key in amd_iommu amdgpu.gttsize ttm.pages_limit; do
    # delete "key=value" tokens (value = non-space run)
    cleaned="$(printf '%s' "$cleaned" | sed -E "s/(^| )${key}=[^ ]*//g")"
done
# Squeeze whitespace.
cleaned="$(printf '%s' "$cleaned" | tr -s ' ' | sed -E 's/^ +| +$//g')"

new_value="$cleaned ${NEW_PARAMS[*]}"
new_value="$(printf '%s' "$new_value" | tr -s ' ' | sed -E 's/^ +| +$//g')"
new_line="GRUB_CMDLINE_LINUX_DEFAULT=\"${new_value}\""

echo
log "Current: ${current_line:-<none>}"
log "New    : ${new_line}"
echo

if [[ $DRY_RUN -eq 1 ]]; then
    warn "--dry-run: no changes written."
    exit 0
fi

if [[ $ASSUME_YES -ne 1 ]]; then
    read -rp "Apply this change to ${GRUB_FILE}? [y/N] " ans
    case "${ans:-N}" in
        y|Y|yes|YES) : ;;
        *) warn "Aborted. No changes made."; exit 0 ;;
    esac
fi

# ----------------------------------------------------------------------------
# 3. Back up, write the new line, regenerate GRUB config.
# ----------------------------------------------------------------------------
backup="${GRUB_FILE}.bak.$(date +%Y%m%d-%H%M%S 2>/dev/null || echo manual)"
log "Backing up ${GRUB_FILE} -> ${backup}"
sudo cp -a "$GRUB_FILE" "$backup"

if [[ -n "$current_line" ]]; then
    # Replace the existing line. Use a tmp file to avoid sed-escaping the value.
    sudo awk -v repl="$new_line" \
        '/^GRUB_CMDLINE_LINUX_DEFAULT=/{print repl; next} {print}' \
        "$GRUB_FILE" | sudo tee "${GRUB_FILE}.tmp" >/dev/null
    sudo mv "${GRUB_FILE}.tmp" "$GRUB_FILE"
else
    printf '%s\n' "$new_line" | sudo tee -a "$GRUB_FILE" >/dev/null
fi

log "Updated ${GRUB_FILE}."

log "Regenerating GRUB configuration (update-grub)..."
if command -v update-grub &>/dev/null; then
    sudo update-grub
else
    sudo grub-mkconfig -o /boot/grub/grub.cfg
fi

echo
log "Kernel parameters applied. Reboot for them to take effect:  sudo reboot"
echo "After reboot, verify inside the distrobox with:  rocminfo | grep -i 'pool\\|size'  or  rocm-smi --showmeminfo vram"
warn "If the system fails to boot, pick the previous kernel entry or restore: sudo cp ${backup} ${GRUB_FILE} && sudo update-grub"
