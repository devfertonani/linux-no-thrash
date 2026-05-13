#!/usr/bin/env bash
# Configure swap and OOM handling on Debian/Ubuntu desktops.
# Idempotent; re-running skips steps already in the desired state.

set -euo pipefail

SWAPFILE=/swapfile
SWAP_SIZE_GB="${SWAP_SIZE_GB:-32}"
SWAPPINESS=10
CACHE_PRESSURE=50

[[ $SWAP_SIZE_GB =~ ^[1-9][0-9]*$ ]] || { echo "error: SWAP_SIZE_GB must be a positive integer (got '$SWAP_SIZE_GB')" >&2; exit 1; }

SYSCTL_FILE=/etc/sysctl.d/99-swap-tuning.conf
EARLYOOM_DEFAULTS=/etc/default/earlyoom

# Processes earlyoom must never kill. Keep the desktop alive under pressure
# (system criticals) and add anything that loses state when killed.
AVOID='^(systemd|systemd-.*|init|kthreadd|sshd|Xorg|Xwayland|gnome-shell|gdm|gdm3|kwin_.*|plasmashell|dbus-daemon|NetworkManager|wpa_supplicant|pulseaudio|pipewire|pipewire-.*|claude)$'

# Processes earlyoom should target first under pressure.
PREFER='^(chrome|chromium|chrome_crashpad|firefox|firefox-bin|brave|opera|vivaldi|slack|discord|spotify|steam|telegram|whatsapp|electron|code|cursor|atom|sublime_text|node|java|python3?|ruby|go|rustc|webpack|vite|next-server|insomnia|postman|dbeaver|virtualbox|qemu)$'

die() { echo "error: $*" >&2; exit 1; }

(( EUID == 0 )) || die "must run as root (sudo bash $0)"
command -v apt-get >/dev/null || die "requires apt-get (Debian/Ubuntu)"

setup_swap() {
  local target_bytes=$((SWAP_SIZE_GB * 1024**3))
  local current_bytes=0

  if swapon --show=NAME --noheadings | grep -qx "$SWAPFILE"; then
    current_bytes=$(swapon --show=NAME,SIZE --bytes --noheadings | awk -v f="$SWAPFILE" '$1==f{print $2}')
  fi

  local other
  other=$(swapon --show=NAME --noheadings | grep -vx "$SWAPFILE" || true)
  [[ -z $other ]] || die "active swap outside $SWAPFILE; deactivate manually before running"

  if (( current_bytes == target_bytes )) && [[ -f $SWAPFILE ]]; then
    echo "swap already $SWAP_SIZE_GB GB"
    return
  fi

  local free_gb
  free_gb=$(df --output=avail -BG / | tail -1 | tr -dc 0-9)
  (( free_gb >= SWAP_SIZE_GB + 5 )) || die "need ${SWAP_SIZE_GB}+5 GB free on /, have ${free_gb}"

  if (( current_bytes > 0 )); then
    # Lower swappiness before swapoff so the kernel does not immediately page
    # cold data back out into the freshly created swapfile.
    sysctl -q vm.swappiness=$SWAPPINESS vm.vfs_cache_pressure=$CACHE_PRESSURE

    local avail used
    avail=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
    used=$(awk '/SwapTotal/{t=$2}/SwapFree/{f=$2}END{print int((t-f)/1024)}' /proc/meminfo)
    (( avail >= used + 2048 )) || die "not enough free RAM (${avail} MB) to absorb ${used} MB of active swap"

    swapoff "$SWAPFILE"
  fi

  rm -f "$SWAPFILE"
  fallocate -l ${SWAP_SIZE_GB}G "$SWAPFILE"
  chmod 600 "$SWAPFILE"
  mkswap -q "$SWAPFILE"
  swapon "$SWAPFILE"
}

ensure_fstab() {
  grep -qE "^[^#]*$SWAPFILE[[:space:]]+(none|swap)" /etc/fstab && return
  echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab
}

apply_sysctl() {
  cat > "$SYSCTL_FILE" <<EOF
vm.swappiness=$SWAPPINESS
vm.vfs_cache_pressure=$CACHE_PRESSURE
EOF
  sysctl -q -p "$SYSCTL_FILE"
}

setup_earlyoom() {
  if ! dpkg -s earlyoom >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y earlyoom
  fi

  # No quotes around the regexes: systemd does whitespace word-splitting on
  # $EARLYOOM_ARGS but does not strip quotes, so quoted values would reach
  # earlyoom with the quotes as literal characters.
  local args="-r 60 -m 10,5 -s 10,5 --avoid $AVOID --prefer $PREFER"

  if grep -qE '^[[:space:]]*EARLYOOM_ARGS=' "$EARLYOOM_DEFAULTS"; then
    # Use # as the sed delimiter; the regex contains | but not #.
    sed -i -E "s#^[[:space:]]*EARLYOOM_ARGS=.*#EARLYOOM_ARGS=\"$args\"#" "$EARLYOOM_DEFAULTS"
  else
    echo "EARLYOOM_ARGS=\"$args\"" >> "$EARLYOOM_DEFAULTS"
  fi

  systemctl enable --now earlyoom >/dev/null
  systemctl restart earlyoom
}

setup_swap
ensure_fstab
apply_sysctl
setup_earlyoom

echo
swapon --show
free -h
sysctl vm.swappiness vm.vfs_cache_pressure
systemctl is-active earlyoom
