#!/usr/bin/env bash
#
# setup-vanilla-vm.sh — Create macOS or Ubuntu VMs (official ISO or Tart OCI) via Apple VZ
#
# Prerequisites installed via Homebrew:
#   - tart (cirruslabs/cli/tart) — CLI for Apple's Virtualization.framework
#     Supports both macOS (IPSW) and Linux (OCI) guests on Apple Silicon.
#
# Usage:
#   bash setup-vanilla-vm.sh                # Ubuntu 24.04 from official ISO (VM: ubuntu-2404)
#   bash setup-vanilla-vm.sh --use-tart-base-images   # Ubuntu 24.04 from ghcr.io OCI
#   bash setup-vanilla-vm.sh --os ubuntu --version 22.04
#   bash setup-vanilla-vm.sh --os ubuntu --gui                    # ubuntu-desktop (default)
#   bash setup-vanilla-vm.sh --os ubuntu --gui xubuntu-desktop
#   bash setup-vanilla-vm.sh --version-list
#   bash setup-vanilla-vm.sh --name my-vm
#   bash setup-vanilla-vm.sh --os macos
#   bash setup-vanilla-vm.sh --os macos --name dev-mac
#   bash setup-vanilla-vm.sh --docker-setup my-vm
#   bash setup-vanilla-vm.sh --ssh-config-from-host my-vm
#   bash setup-vanilla-vm.sh --name my-vm --ssh-config-from-host
#   bash setup-vanilla-vm.sh --clear-iso-cache   # Remove ~/.local/share/vms/iso/* (only this flag)
#   bash setup-vanilla-vm.sh --help
#
# After setup (Ubuntu server / no --gui):
#   tart run <vm-name> --no-graphics        # no host window; use SSH
#   sshpass -p '<password>' ssh -o StrictHostKeyChecking=no <user>@$(tart ip <vm-name>)
# With --gui (desktop), use: tart run <vm-name>  # graphical window
#
# New Ubuntu VMs are started headlessly, provisioned over SSH (SPICE tools and
# optional desktop), then shut down automatically.
#
# VM storage: ~/.tart/vms/
# Image cache: ~/.tart/cache/
# Official ISOs (default; no --use-tart-base-images): cached under ~/.local/share/vms/iso/
# Autoinstall nocloud: seed files served via CIDATA ISO (no network required).
#
set -euo pipefail
#set -x 

# ── Colors (disabled if output is not a terminal) ─────────────────────────────
if [ -t 1 ]; then
  BOLD='\033[1m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  RED='\033[0;31m'
  CYAN='\033[0;36m'
  RESET='\033[0m'
else
  BOLD='' GREEN='' YELLOW='' RED='' CYAN='' RESET=''
fi

info()  { echo -e "${BOLD}${CYAN}==> $1${RESET}"; }
skip()  { echo -e "  ${YELLOW}[skip]${RESET} $1"; }
ok()    { echo -e "  ${GREEN}[ok]${RESET} $1"; }
err()   { echo -e "  ${RED}[error]${RESET} $1" >&2; }

usage() {
  echo "Usage: setup-vanilla-vm.sh [--os ubuntu|macos] [--version <ver>] [--use-tart-base-images] [--name <vm-name>] [--gui] [--offline] [--ssh-config-from-host]"
  echo "       setup-vanilla-vm.sh --docker-setup <vm-name>"
  echo "       setup-vanilla-vm.sh --ssh-config-from-host <vm-name>"
  echo "       setup-vanilla-vm.sh --version-list"
  echo "       setup-vanilla-vm.sh --clear-iso-cache"
  echo ""
  echo "Options:"
  echo "  --os <ubuntu|macos>           Guest OS (default: ubuntu)"
  echo "  --version <ver>               Ubuntu version (default: 24.04). Requires --os ubuntu."
  echo "  --use-tart-base-images        For Ubuntu: use OCI (ghcr.io/cirruslabs/ubuntu). Default is official ISO + autoinstall."
  echo "  --version-list                List OCI and ISO-possible Ubuntu release lines, then exit"
  echo "  --name <vm-name>              Custom VM name"
  echo "  --gui [desktop]               Ubuntu: install a desktop (ubuntu-desktop|xubuntu-desktop|lubuntu-desktop|lightdm)."
  echo "                                Default: ubuntu-desktop. (with --use-tart-base-images: desktop via packages.)"
  echo "  --docker-setup <name>         Install Docker in an existing VM + configure host"
  echo "  --ssh-config-from-host [name] Copy host ~/.ssh/ keys (id_*, *.pem) into VM."
  echo "  --offline                     Ubuntu ISO: skip updates during autoinstall (no internet needed for base install)"
  echo "  --clear-iso-cache             Remove downloaded/patched ISOs under ~/.local/share/vms/iso/ (use alone; no other flags)"
  echo "  --user <username>             VM login username (default: admin)"
  echo "  --password <password>         VM login password (default: admin)"
  echo "  --debug-no-headless           Run VMs with graphics window instead of headless (debug)"
  echo "  --help                        Show this help message"
}

# ── Shared constants ─────────────────────────────────────────────────────────
VM_USER="admin"
VM_PASSWORD="admin"

SSH_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o PubkeyAuthentication=no
  -o LogLevel=ERROR
  -o ConnectTimeout=10
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=120
)

# ── Shared helpers ────────────────────────────────────────────────────────────

vm_exists() {
  tart list -q 2>/dev/null | grep -qx "$1"
}

vm_is_running() {
  tart list 2>/dev/null | awk -v n="$1" '$2 == n { print $NF }' | grep -qx "running"
}

# Wait for tart to report the guest IP (up to ~2 min).
# Sets the variable named by $2 (default: VM_IP) to the IP address.
wait_for_vm_ip() {
  local vm_name="$1" var_name="${2:-VM_IP}" ip=""
  info "Waiting for guest IP address..."
  for _ in $(seq 1 60); do
    ip="$(tart ip "$vm_name" 2>/dev/null || true)"
    if [[ -n "$ip" ]]; then
      eval "$var_name=\$ip"
      ok "Guest IP: ${ip}"
      return 0
    fi
    sleep 2
  done
  err "Timed out waiting for VM IP. Is the VM booting? Try: tart ip ${vm_name}"
  return 1
}

# Wait for SSH to accept connections (up to ~2 min).
wait_for_ssh() {
  local user="$1" password="$2" ip="$3"
  info "Waiting for SSH..."
  for _ in $(seq 1 40); do
    if sshpass -p "$password" ssh "${SSH_OPTS[@]}" \
        "${user}@${ip}" "true" 2>/dev/null; then
      ok "SSH is up"
      return 0
    fi
    sleep 3
  done
  err "SSH did not become ready in time. Check credentials and guest sshd."
  return 1
}

# Boot VM headlessly, wait for IP + SSH. Prints the PID and IP.
# Sets: _VM_PID, _VM_IP  (caller must read these after return)
# Also installs a cleanup trap for the tart process.
start_vm_headless() {
  local vm_name="$1" user="$2" password="$3"
  _VM_PID="" _VM_IP=""

  local tart_args=("$vm_name")
  if [[ "$DEBUG_NO_HEADLESS" != true ]]; then
    tart_args+=(--no-graphics)
    info "Starting VM '${vm_name}' headlessly..."
  else
    info "Starting VM '${vm_name}' with graphics window (debug)..."
  fi
  tart run "${tart_args[@]}" &
  _VM_PID=$!

  # shellcheck disable=SC2064
  trap "kill $_VM_PID 2>/dev/null; wait $_VM_PID 2>/dev/null || true" EXIT INT TERM

  wait_for_vm_ip "$vm_name" _VM_IP
  wait_for_ssh "$user" "$password" "$_VM_IP"
}

stop_vm() {
  local user="$1" password="$2" ip="$3" pid="$4"
  info "Shutting down the guest..."
  sshpass -p "$password" ssh "${SSH_OPTS[@]}" \
    "${user}@${ip}" "sudo shutdown -h now" 2>/dev/null || true

  info "Waiting for VM to shut down..."
  wait "$pid" 2>/dev/null || true
  trap - EXIT INT TERM
  ok "VM stopped"
}

ISO_CACHE_DIR="${HOME}/.local/share/vms/iso"

# Newest point-release arm64 live ISO for series (e.g. 24.04). variant: "server" | "desktop"
resolve_ubuntu_arm64_iso_url() {
  local version="${1?}" variant="${2?}" URL
  if ! URL="$(
    UBUNTU_SERIES="$version" V="$variant" python3 <<'PY'
import re, os, sys, urllib.request
series, v = os.environ.get("UBUNTU_SERIES", ""), os.environ.get("V", "")
u = f"https://cdimage.ubuntu.com/releases/{series}/release/"
try:
    with urllib.request.urlopen(u, timeout=90) as r:
        html = r.read().decode("utf-8", "replace")
except Exception as e:
    print(e, file=sys.stderr)
    sys.exit(1)
if v == "server":
    names = re.findall(r"ubuntu-(\d+\.\d+\.\d+)-live-server-arm64\.iso", html)
    suffix = "live-server-arm64"
else:
    names = re.findall(r"ubuntu-(\d+\.\d+\.\d+)-desktop-arm64\.iso", html)
    suffix = "desktop-arm64"
if not names:
    sys.exit(1)
def vkey(s):
    return tuple(int(x) for x in s.split("."))
best = max(names, key=vkey)
print(
    f"https://cdimage.ubuntu.com/releases/{series}/release/ubuntu-{best}-{suffix}.iso",
    end="",
)
PY
  )"; then
    err "Could not find arm64 ${variant} ISO for Ubuntu ${version} (cdimage.ubuntu.com/releases/${version}/)"
    return 1
  fi
  if [[ -z "$URL" ]]; then
    return 1
  fi
  echo "$URL"
  return 0
}

# Minimum bytes to treat a cached file as a complete Ubuntu live ISO (avoid reusing a failed partial).
ISO_MIN_BYTES=$((200 * 1024 * 1024))

# Verify a downloaded ISO against the SHA256SUMS published alongside it.
# $1 = full URL of the ISO   $2 = local path to the ISO file
verify_iso_checksum() {
  local iso_url="$1" iso_path="$2"
  local base_url sums_url sums_file filename expected actual
  base_url="${iso_url%/*}"
  sums_url="${base_url}/SHA256SUMS"
  filename="$(basename "$iso_url")"
  sums_file="${ISO_CACHE_DIR}/SHA256SUMS-${filename%.iso}"
  if ! curl -fsSL --connect-timeout 30 -o "$sums_file" "$sums_url" 2>/dev/null; then
    skip "SHA256SUMS not available; skipping integrity check"
    return 0
  fi
  expected="$(grep -F "$filename" "$sums_file" | awk '{print $1}' | head -1)"
  if [[ -z "$expected" ]]; then
    skip "No checksum entry for ${filename} in SHA256SUMS; skipping integrity check"
    return 0
  fi
  actual="$(shasum -a 256 "$iso_path" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    err "SHA-256 mismatch for $(basename "$iso_path"): expected ${expected}, got ${actual}"
    return 1
  fi
  ok "SHA-256 verified: $(basename "$iso_path")"
  return 0
}

# Prints ISO path as the only stdout line (for command substitution). Progress to stderr.
# Caches by URL basename under ISO_CACHE_DIR; re-downloads if missing, empty, or too small.
ensure_iso_cached() {
  local url="$1" dest sz chk
  dest="${ISO_CACHE_DIR}/$(basename "$url")"
  mkdir -p "$ISO_CACHE_DIR"
  chk="${ISO_CACHE_DIR}/.verified-$(basename "$url")"
  if [[ -f "$dest" && -s "$dest" ]]; then
    sz="$(stat -f%z "$dest" 2>/dev/null || echo 0)"
    if [[ "$sz" -ge "$ISO_MIN_BYTES" ]]; then
      if [[ -f "$chk" ]]; then
        echo -e "  ${YELLOW}[skip]${RESET} Using cached ISO ($((sz / 1024 / 1024)) MiB): $dest" >&2
        echo "$dest"
        return 0
      fi
      echo -e "  ${YELLOW}[skip]${RESET} Cached ISO found; verifying checksum..." >&2
      if verify_iso_checksum "$url" "$dest"; then
        touch "$chk"
        echo "$dest"
        return 0
      fi
      err "Cached ISO failed checksum; re-downloading"
      rm -f "$dest" "$chk" 2>/dev/null || true
    fi
    echo -e "  ${YELLOW}[skip]${RESET} Cached file too small or incomplete; re-downloading: $dest" >&2
    rm -f "$dest" 2>/dev/null || true
  fi
  echo -e "${BOLD}${CYAN}==> Downloading $(basename "$url") into ${ISO_CACHE_DIR} ...${RESET}" >&2
  if ! curl -fL --connect-timeout 30 -C - -o "$dest" --progress-bar "$url"; then
    rm -f "$dest" 2>/dev/null || true
    err "Failed to download $url"
    return 1
  fi
  sz="$(stat -f%z "$dest" 2>/dev/null || echo 0)"
  if [[ "$sz" -lt "$ISO_MIN_BYTES" ]]; then
    rm -f "$dest" 2>/dev/null || true
    err "Downloaded file is too small ($((sz / 1024 / 1024)) MiB); expected a full live ISO."
    return 1
  fi
  if ! verify_iso_checksum "$url" "$dest"; then
    rm -f "$dest" "$chk" 2>/dev/null || true
    err "Downloaded ISO failed integrity check. Try again or download manually."
    return 1
  fi
  touch "$chk"
  echo "$dest"
  return 0
}

# Patch an Ubuntu live ISO: append `autoinstall ds=nocloud` to the casper vmlinuz line.
patch_iso_for_autoinstall() {
  local in_iso="$1" out_iso="$2"
  local tdir pgrub
  tdir="$(mktemp -d /tmp/tart-iso-XXXXXX)"
  pgrub="${tdir}/grub.cfg"
  if ! command -v xorriso &>/dev/null; then
    err "xorriso is required to patch the ISO. Install: brew install xorriso"
    return 1
  fi
  if ! xorriso -osirrox on -indev "$in_iso" -extract /boot/grub/grub.cfg "$pgrub" 2>/dev/null; then
    rm -rf "$tdir"
    err "Could not extract /boot/grub/grub.cfg from the ISO (xorriso + valid Ubuntu live ISO?)"
    return 1
  fi
  chmod u+w "$pgrub"
  python3 - "$pgrub" <<'PY' || { rm -rf "$tdir"; return 1; }
import re, sys
path = sys.argv[1]
extra = " autoinstall ds=nocloud"
with open(path, "r", encoding="utf-8", errors="replace") as f:
  s = f.read()
if "autoinstall" in s:
  print("grub already contains autoinstall; refusing to double-patch", file=sys.stderr)
  sys.exit(1)
lines = s.splitlines(keepends=True)
out = []
patched = False
for line in lines:
  if (
    not patched
    and re.search(r"^\s*linux\s+/.*/vmlinuz", line)
    and "autoinstall" not in line
  ):
    if re.search(r"---\s*$", line.rstrip("\n")):
      line = re.sub(
        r"(\s)---\s*(\n?)$",
        r"\1" + extra + r" ---\2",
        line,
        count=1,
      )
    else:
      line = line.rstrip() + extra + " ---\n"
    patched = True
  out.append(line)
s2 = "".join(out)
if not patched:
  print("No install menu linux /vmlinuz line found in grub.cfg", file=sys.stderr)
  sys.exit(1)
if "autoinstall" not in s2:
  print("Could not inject autoinstall; grub layout unexpected", file=sys.stderr)
  sys.exit(1)
with open(path, "w", encoding="utf-8") as f:
  f.write(s2)
sys.exit(0)
PY
  cp -f "$in_iso" "$out_iso" || { rm -rf "$tdir"; return 1; }
  if ! xorriso -dev "$out_iso" -boot_image any keep -overwrite on -cpr "$pgrub" /boot/grub/grub.cfg -- -commit; then
    err "Failed to put patched grub into ISO (xorriso -cpr). Check: brew install xorriso"
    rm -f "$out_iso" "$pgrub" 2>/dev/null || true
    rm -rf "$tdir"
    return 1
  fi
  rm -rf "$tdir"
  return 0
}

write_autoinstall_seed() {
  local destdir="$1" offline="${2:-false}" hashpass
  if ! hashpass="$(printf '%s' "$VM_PASSWORD" | openssl passwd -6 -stdin)"; then
    return 1
  fi
  mkdir -p "$destdir"
  {
    echo "#cloud-config"
    echo "autoinstall:"
    echo "  version: 1"
    echo "  source:"
    echo "    type: d-i"
    if [[ "$offline" == true ]]; then
      echo "  updates: disabled"
      echo "  apt:"
      echo "    disable_suites: [security, updates]"
    fi
    echo "  storage:"
    echo "    layout:"
    echo "      name: direct"
    echo "  identity:"
    echo "    hostname: ubuntu"
    echo "    username: ${VM_USER}"
    echo "    password: '${hashpass}'"
    echo "  ssh:"
    echo "    install-server: true"
    echo "    allow-pw: true"
    echo "  late-commands:"
    echo "    - curtin in-target -- sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/* 2>/dev/null || true"
    echo "    - curtin in-target -- systemctl enable --now ssh 2>/dev/null || true"
  } > "$destdir/user-data"
  cat > "$destdir/meta-data" <<SEED
instance-id: tart-ubuntu-${UBUNTU_VERSION//./}
local-hostname: ubuntu
SEED
}

# $1: vm_name  $2: user $3: pass  $4: optional max iterations (default 200)
# Polls for SSH; longer for fresh ISO install.
wait_for_ssh_long() {
  local user="$1" password="$2" ip="$3" maxit="${4:-200}"
  info "Waiting for SSH (autoinstall may take many minutes)..."
  local n=0
  for _ in $(seq 1 "$maxit"); do
    if sshpass -p "$password" ssh -o ConnectTimeout=5 -o ServerAliveCountMax=2 -o ServerAliveInterval=5 \
         "${SSH_OPTS[@]}" \
        "${user}@${ip}" "true" 2>/dev/null; then
      ok "SSH is up"
      return 0
    fi
    n=$((n+1))
    if (( n % 20 == 0 )); then
      info "  ... still waiting for SSH (${n}/${maxit}) at ${ip}"
    fi
    sleep 10
  done
  err "SSH did not become ready in time."
  return 1
}

# Download arm64 live ISO, autoinstall via nocloud CIDATA disk + xorriso-patched grub, then power off.
# Expects: VM_NAME, UBUNTU_VERSION, VM_DISK_GB, VM_CPUS, VM_MEMORY_MB, INSTALL_DESKTOP.
iso_install_ubuntu_vm() {
  local variant="server" dlurl rawiso seed_dir patched seed_iso
  [[ "$INSTALL_DESKTOP" == true ]] && variant="desktop"

  if ! command -v xorriso &>/dev/null; then
    info "Installing xorriso (required to patch the live ISO and build CIDATA seed)..."
    brew install xorriso
    ok "xorriso installed"
  fi

  dlurl="$(resolve_ubuntu_arm64_iso_url "$UBUNTU_VERSION" "$variant")" || return 1
  rawiso="$(ensure_iso_cached "$dlurl")" || return 1

  seed_dir="$(mktemp -d /tmp/tart-seed-XXXXXX)"
  write_autoinstall_seed "$seed_dir" "$OFFLINE_INSTALL" || { rm -rf "$seed_dir"; return 1; }

  patched="${ISO_CACHE_DIR}/autoinstall-${VM_NAME}.iso"
  seed_iso="${ISO_CACHE_DIR}/cidata-${VM_NAME}.iso"

  info "Building CIDATA seed ISO..."
  if ! xorriso -as mkisofs -volid CIDATA -joliet -rock \
      -o "$seed_iso" "$seed_dir" 2>/dev/null; then
    err "Failed to create CIDATA ISO with xorriso"
    rm -rf "$seed_dir"
    return 1
  fi
  rm -rf "$seed_dir"
  ok "CIDATA seed ISO: $seed_iso"

  info "Patching a copy of the ISO to pass autoinstall + nocloud..."
  if ! patch_iso_for_autoinstall "$rawiso" "$patched"; then
    return 1
  fi

  info "Creating Linux VM '${VM_NAME}' and running the installer (autoinstall; often 20–60+ minutes)..."
  tart create "$VM_NAME" --linux --disk-size "$VM_DISK_GB"
  tart set "$VM_NAME" \
    --cpu "$VM_CPUS" \
    --memory "$VM_MEMORY_MB" \
    --disk-size "$VM_DISK_GB"

  local iso_tart_args=("$VM_NAME")
  if [[ "$DEBUG_NO_HEADLESS" != true ]]; then
    iso_tart_args+=(--no-graphics)
  fi
  iso_tart_args+=(--disk "$patched" --disk "$seed_iso")
  tart run "${iso_tart_args[@]}"
  ok "Autoinstall run finished (VM off). Next: first normal boot + SPICE provisioning."
  return 0
}

# ── Parse flags ────────────────────────────────────────────────────────────────
GUEST_OS="ubuntu"
UBUNTU_VERSION="24.04"
UBUNTU_VERSION_SET=false
USE_TART_BASE_IMAGES=false
USE_ISO_INSTALL=false
VERSION_LIST=false
CLEAR_ISO_CACHE=false
INSTALL_DESKTOP=false
DESKTOP_PACKAGE="ubuntu-desktop"
CLI_VM_NAME=""
DOCKER_SETUP_VM=""
COPY_SSH_VM=""
COPY_SSH_AFTER_CREATE=false
OFFLINE_INSTALL=false
DEBUG_NO_HEADLESS=false
OTHER_FLAGS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --os)
      OTHER_FLAGS=true
      shift
      GUEST_OS="${1:-}"
      if [[ -z "$GUEST_OS" ]]; then
        err "--os requires a value (ubuntu, macos)"; exit 1
      fi
      ;;
    --version)
      OTHER_FLAGS=true
      UBUNTU_VERSION_SET=true
      shift
      UBUNTU_VERSION="${1:-}"
      if [[ -z "$UBUNTU_VERSION" ]]; then
        err "--version requires a value (e.g. 22.04, 24.04)"; exit 1
      fi
      ;;
    --version-list)
      VERSION_LIST=true
      ;;
    --use-tart-base-images)
      USE_TART_BASE_IMAGES=true
      ;;
    --clear-iso-cache)
      CLEAR_ISO_CACHE=true
      ;;
    --gui)
      OTHER_FLAGS=true
      INSTALL_DESKTOP=true
      if [[ $# -ge 2 && ! "$2" =~ ^- ]]; then
        shift
        DESKTOP_PACKAGE="$1"
        case "$DESKTOP_PACKAGE" in
          ubuntu-desktop|xubuntu-desktop|lubuntu-desktop|lightdm) ;;
          *) err "--gui accepts: ubuntu-desktop, xubuntu-desktop, lubuntu-desktop, lightdm (got '$DESKTOP_PACKAGE')"; exit 1 ;;
        esac
      fi
      ;;
    --offline)
      OTHER_FLAGS=true
      OFFLINE_INSTALL=true
      ;;
    --name)
      OTHER_FLAGS=true
      shift
      CLI_VM_NAME="${1:-}"
      if [[ -z "$CLI_VM_NAME" ]]; then
        err "--name requires a value"; exit 1
      fi
      ;;
    --docker-setup)
      shift
      DOCKER_SETUP_VM="${1:-}"
      if [[ -z "$DOCKER_SETUP_VM" ]]; then
        err "--docker-setup requires a VM name"; exit 1
      fi
      ;;
    --ssh-config-from-host)
      if [[ $# -ge 2 && ! "$2" =~ ^- ]]; then
        shift
        COPY_SSH_VM="$1"
      else
        COPY_SSH_AFTER_CREATE=true
        OTHER_FLAGS=true
      fi
      ;;
    --user)
      shift
      VM_USER="${1:-}"
      if [[ -z "$VM_USER" ]]; then
        err "--user requires a value"; exit 1
      fi
      ;;
    --password)
      shift
      VM_PASSWORD="${1:-}"
      if [[ -z "$VM_PASSWORD" ]]; then
        err "--password requires a value"; exit 1
      fi
      ;;
    --debug-no-headless)
      DEBUG_NO_HEADLESS=true
      ;;
    *)
      err "Unknown option: $1"
      usage >&2
      exit 1
      ;;
  esac
  shift
done

# ── --clear-iso-cache: must be the only action ───────────────────────────────
if [[ "$CLEAR_ISO_CACHE" == true ]]; then
  if [[ "$OTHER_FLAGS" == true || "$VERSION_LIST" == true ]] \
     || [[ -n "$DOCKER_SETUP_VM" || -n "$COPY_SSH_VM" ]] \
     || [[ "$COPY_SSH_AFTER_CREATE" == true ]] \
     || [[ "$USE_TART_BASE_IMAGES" == true ]]; then
    err "--clear-iso-cache must be used on its own (no other options)"
    exit 1
  fi
  info "Clearing local ISO cache at ${ISO_CACHE_DIR}..."
  if [[ -d "$ISO_CACHE_DIR" ]]; then
    rm -rf "${ISO_CACHE_DIR}"
  fi
  mkdir -p "$ISO_CACHE_DIR"
  ok "ISO cache cleared."
  exit 0
fi

# ── --version-list: OCI tags + ISO hint ───────────────────────────────────────
if [[ "$VERSION_LIST" == true ]]; then
  info "Fetching OCI tags from ghcr.io/cirruslabs/ubuntu (for --use-tart-base-images)..."
  _token="$(curl -sf "https://ghcr.io/token?scope=repository:cirruslabs/ubuntu:pull" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))")" || true
  if [[ -z "$_token" ]]; then
    err "Failed to authenticate with ghcr.io"; exit 1
  fi
  _tags="$(curl -sf -H "Authorization: Bearer $_token" \
    "https://ghcr.io/v2/cirruslabs/ubuntu/tags/list" \
    | python3 -c "
import sys, json, re
tags = json.load(sys.stdin).get('tags', [])
versions = sorted([t for t in tags if re.fullmatch(r'\d+\.\d+', t)])
for v in versions:
    print(v)
")" || true
  if [[ -z "$_tags" ]]; then
    err "Could not retrieve tags from ghcr.io/cirruslabs/ubuntu"; exit 1
  fi
  echo ""
  echo "Tart OCI (use with --use-tart-base-images):"
  echo "$_tags" | while read -r v; do
    if [[ "$v" == "$UBUNTU_VERSION" ]]; then
      echo -e "  ${GREEN}${v}${RESET} (default)"
    else
      echo -e "  ${v}"
    fi
  done
  echo ""
  echo "Official ISO (default, no --use-tart-base-images): use an LTS that has arm64 live images on"
  echo "  https://cdimage.ubuntu.com/releases/ e.g. 22.04, 24.04 (script picks latest .N ISO)."
  echo ""
  echo "Usage: bash setup-vanilla-vm.sh --os ubuntu --version <ver>   # ISO + autoinstall"
  echo "       bash setup-vanilla-vm.sh --use-tart-base-images --os ubuntu --version <ver>   # OCI clone"
  exit 0
fi

if [[ -n "$DOCKER_SETUP_VM" && "$OTHER_FLAGS" == true ]]; then
  err "--docker-setup must be used on its own (no --os, --gui, or --name)"
  exit 1
fi

if [[ -n "$DOCKER_SETUP_VM" && "$USE_TART_BASE_IMAGES" == true ]]; then
  err "--docker-setup cannot be combined with --use-tart-base-images"
  exit 1
fi

if [[ -n "$COPY_SSH_VM" ]]; then
  if [[ "$OTHER_FLAGS" == true || -n "$DOCKER_SETUP_VM" || "$USE_TART_BASE_IMAGES" == true ]]; then
    err "--ssh-config-from-host <vm-name> must be used on its own (no --os, --gui, --name, --docker-setup, --use-tart-base-images)"
    exit 1
  fi
fi

if [[ -n "$DOCKER_SETUP_VM" && "$COPY_SSH_AFTER_CREATE" == true ]]; then
  err "--ssh-config-from-host cannot be combined with --docker-setup"
  exit 1
fi

if [[ -n "$CLI_VM_NAME" ]]; then
  if [[ ! "$CLI_VM_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
    err "Invalid VM name '$CLI_VM_NAME' (use letters, digits, . _ - only; no spaces)"
    exit 1
  fi
fi

if [[ "$GUEST_OS" != "ubuntu" && "$GUEST_OS" != "macos" ]]; then
  err "--os must be 'ubuntu' or 'macos' (got '$GUEST_OS')"
  exit 1
fi

if [[ "$UBUNTU_VERSION_SET" == true && "$GUEST_OS" != "ubuntu" ]]; then
  err "--version can only be used with --os ubuntu (got --os '$GUEST_OS')"
  exit 1
fi

if [[ "$OFFLINE_INSTALL" == true && "$GUEST_OS" != "ubuntu" ]]; then
  err "--offline can only be used with --os ubuntu"
  exit 1
fi

if [[ "$OFFLINE_INSTALL" == true && "$USE_TART_BASE_IMAGES" == true ]]; then
  err "--offline cannot be combined with --use-tart-base-images (ISO install only)"
  exit 1
fi

if [[ "$GUEST_OS" == "macos" && "$INSTALL_DESKTOP" == true ]]; then
  echo "Note: --gui is ignored for macOS (always has a desktop)" >&2
  INSTALL_DESKTOP=false
fi

if [[ "$GUEST_OS" == "macos" && "$USE_TART_BASE_IMAGES" == true ]]; then
  err "--use-tart-base-images applies only to Ubuntu (Tart OCI base images from ghcr.io)."
  exit 1
fi

if [[ "$GUEST_OS" == "macos" && "$COPY_SSH_AFTER_CREATE" == true ]]; then
  echo "Warning: --ssh-config-from-host is only supported for Ubuntu VMs; ignoring for macOS." >&2
  echo "  (macOS VMs use Setup Assistant for user creation and have no admin/admin default.)" >&2
  COPY_SSH_AFTER_CREATE=false
fi

# ── Validate platform ─────────────────────────────────────────────────────────
ARCH="$(uname -m)"
if [[ "$ARCH" != "arm64" ]]; then
  err "Apple Virtualization Framework requires Apple Silicon (arm64)."
  err "Detected architecture: $ARCH"
  exit 1
fi

# ── Prerequisites ──────────────────────────────────────────────────────────────
echo ""
info "Checking prerequisites..."

if ! command -v brew &>/dev/null; then
  err "Homebrew is required. Install it or run setup-mac.sh first."
  exit 1
fi

if ! command -v tart &>/dev/null; then
  info "Installing tart (Apple Virtualization CLI)..."
  brew install cirruslabs/cli/tart
  ok "tart installed"
else
  skip "tart already installed ($(tart --version 2>/dev/null || echo 'unknown'))"
fi

# ── Docker setup for an existing VM ───────────────────────────────────────────
setup_docker() {
  local vm_name="$1"

  if ! vm_exists "$vm_name"; then
    err "VM '${vm_name}' does not exist. Create it first with: bash setup-vanilla-vm.sh --name ${vm_name}"
    exit 1
  fi

  if ! command -v sshpass &>/dev/null; then
    info "Installing sshpass..."
    brew install sshpass
    ok "sshpass installed"
  fi

  if ! command -v docker &>/dev/null; then
    info "Installing Docker CLI on host..."
    brew install docker
    ok "Docker CLI installed"
  fi

  local vm_started_by_us=false
  local vm_ip vm_pid=""

  if vm_is_running "$vm_name"; then
    info "VM '${vm_name}' is already running; waiting for IP..."
    vm_ip="$(tart ip "$vm_name" --wait 60 2>/dev/null || true)"
    if [[ -z "$vm_ip" ]]; then
      err "Timed out waiting for VM IP. Try: tart ip ${vm_name}"
      exit 1
    fi
    ok "Guest IP: ${vm_ip}"
    wait_for_ssh "$VM_USER" "$VM_PASSWORD" "$vm_ip"
  else
    vm_started_by_us=true
    start_vm_headless "$vm_name" "$VM_USER" "$VM_PASSWORD"
    vm_ip="$_VM_IP"
    vm_pid="$_VM_PID"
  fi

  local ssh_key="${HOME}/.ssh/id_ed25519"
  if [[ ! -f "$ssh_key" ]]; then
    info "Generating SSH key pair (ed25519)..."
    ssh-keygen -t ed25519 -f "$ssh_key" -N "" -q
    ok "SSH key created: ${ssh_key}"
  fi

  info "Copying SSH public key to guest..."
  sshpass -p "$VM_PASSWORD" ssh-copy-id -i "${ssh_key}.pub" \
    "${SSH_OPTS[@]}" "${VM_USER}@${vm_ip}"
  ok "Public key installed in guest"

  info "Installing Docker Engine in guest '${vm_name}'..."
  sshpass -p "$VM_PASSWORD" ssh "${SSH_OPTS[@]}" "${VM_USER}@${vm_ip}" bash -s <<'DOCKER_INSTALL'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

if command -v docker &>/dev/null; then
  echo ">>> Docker already installed: $(docker --version)"
else
  echo ">>> Installing Docker via official convenience script..."
  curl -fsSL https://get.docker.com | sudo sh
fi

if ! id -nG "$USER" | grep -qw docker; then
  echo ">>> Adding $USER to docker group..."
  sudo usermod -aG docker "$USER"
fi

sudo systemctl enable --now docker
echo ">>> Docker ready: $(docker --version)"
DOCKER_INSTALL

  ok "Docker Engine installed and running in guest"

  local ssh_config="${HOME}/.ssh/config"
  local host_alias="docker-${vm_name}"

  mkdir -p "${HOME}/.ssh"
  chmod 700 "${HOME}/.ssh"

  if grep -qF "Host ${host_alias}" "$ssh_config" 2>/dev/null; then
    skip "SSH config entry '${host_alias}' already exists in ${ssh_config}"
  else
    info "Adding SSH config entry '${host_alias}' to ${ssh_config}..."
    cat >> "$ssh_config" <<SSH_BLOCK

# Docker VM: ${vm_name} (added by setup-vanilla-vm.sh --docker-setup)
Host ${host_alias}
    HostName ${vm_ip}
    User ${VM_USER}
    IdentityFile ${ssh_key}
    IdentitiesOnly yes
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
SSH_BLOCK
    chmod 600 "$ssh_config"
    ok "SSH config entry added: Host ${host_alias} -> ${vm_ip}"
  fi

  if docker context inspect "$host_alias" &>/dev/null 2>&1; then
    skip "Docker context '${host_alias}' already exists"
  else
    info "Creating Docker context '${host_alias}'..."
    docker context create "$host_alias" \
      --docker "host=ssh://${VM_USER}@${host_alias}"
    ok "Docker context created: ${host_alias}"
  fi

  if [[ "$vm_started_by_us" == true ]]; then
    stop_vm "$VM_USER" "$VM_PASSWORD" "$vm_ip" "$vm_pid"
  fi

  echo ""
  echo -e "${BOLD}${GREEN}==> Docker setup complete!${RESET}"
  echo ""
  echo -e "  VM name        : ${CYAN}${vm_name}${RESET}"
  echo -e "  SSH alias      : ${CYAN}${host_alias}${RESET}"
  echo -e "  Docker context : ${CYAN}${host_alias}${RESET}"
  echo ""
  echo -e "  ${YELLOW}Usage:${RESET}"
  echo -e "    1. Start the VM:   ${CYAN}tart run ${vm_name} --no-graphics 2>/dev/null & disown${RESET}"
  echo -e "    2. Switch context: ${CYAN}docker context use ${host_alias}${RESET}"
  echo -e "    3. Use Docker:     ${CYAN}docker ps${RESET}"
  echo ""
  echo -e "  ${YELLOW}Note:${RESET} The SSH config uses a fixed IP (${vm_ip})."
  echo -e "  If the VM gets a new IP after reboot, update HostName in ${ssh_config}."
}

if [[ -n "$DOCKER_SETUP_VM" ]]; then
  setup_docker "$DOCKER_SETUP_VM"
  exit 0
fi

# ── Copy host's SSH keys (~/.ssh/id_*, *.pem) into a VM ─────────────────────
copy_ssh_config_from_host() {
  local vm_name="$1"

  if ! vm_exists "$vm_name"; then
    err "VM '${vm_name}' does not exist."
    exit 1
  fi

  local host_ssh_dir="${HOME}/.ssh"
  if [[ ! -d "$host_ssh_dir" ]]; then
    err "Host has no ${host_ssh_dir} directory; nothing to copy."
    exit 1
  fi

  if ! command -v sshpass &>/dev/null; then
    info "Installing sshpass..."
    brew install sshpass
    ok "sshpass installed"
  fi

  local items=()
  local f
  for f in "$host_ssh_dir"/id_* "$host_ssh_dir"/*.pem; do
    [[ -f "$f" ]] && items+=("$f")
  done

  if [[ ${#items[@]} -eq 0 ]]; then
    skip "No SSH keys (id_*, *.pem) found under ${host_ssh_dir}; nothing to copy."
    return 0
  fi

  local vm_started_by_us=false
  local vm_ip vm_pid=""

  if vm_is_running "$vm_name"; then
    info "VM '${vm_name}' is already running; waiting for IP..."
    vm_ip="$(tart ip "$vm_name" --wait 60 2>/dev/null || true)"
    if [[ -z "$vm_ip" ]]; then
      err "Timed out waiting for VM IP. Try: tart ip ${vm_name}"
      exit 1
    fi
    ok "Guest IP: ${vm_ip}"
    wait_for_ssh "$VM_USER" "$VM_PASSWORD" "$vm_ip"
  else
    vm_started_by_us=true
    start_vm_headless "$vm_name" "$VM_USER" "$VM_PASSWORD"
    vm_ip="$_VM_IP"
    vm_pid="$_VM_PID"
  fi

  info "Copying ${#items[@]} SSH file(s) from ${host_ssh_dir} to guest /home/${VM_USER}/.ssh/..."
  sshpass -p "$VM_PASSWORD" ssh "${SSH_OPTS[@]}" "${VM_USER}@${vm_ip}" \
    "mkdir -p ~/.ssh && chmod 700 ~/.ssh"
  sshpass -p "$VM_PASSWORD" scp "${SSH_OPTS[@]}" "${items[@]}" \
    "${VM_USER}@${vm_ip}:.ssh/"
  sshpass -p "$VM_PASSWORD" ssh "${SSH_OPTS[@]}" "${VM_USER}@${vm_ip}" bash -s <<'FIXPERM'
set -euo pipefail
cd ~/.ssh
chmod 700 .
for f in id_* *.pem; do
  [ -f "$f" ] || continue
  case "$f" in
    *.pub) chmod 644 "$f" ;;
    *)     chmod 600 "$f" ;;
  esac
done
FIXPERM
  ok "SSH configuration copied to guest '${vm_name}'"

  if [[ "$vm_started_by_us" == true ]]; then
    stop_vm "$VM_USER" "$VM_PASSWORD" "$vm_ip" "$vm_pid"
  fi
}

if [[ -n "$COPY_SSH_VM" ]]; then
  copy_ssh_config_from_host "$COPY_SSH_VM"
  exit 0
fi

# ══════════════════════════════════════════════════════════════════════════════
#  macOS VM
# ══════════════════════════════════════════════════════════════════════════════
if [[ "$GUEST_OS" == "macos" ]]; then

  if [[ -n "$CLI_VM_NAME" ]]; then
    VM_NAME="$CLI_VM_NAME"
  else
    VM_NAME="macos-vm"
  fi
  VM_CPUS=4
  VM_MEMORY_MB=8192
  VM_DISK_GB=80

  echo ""
  echo -e "${BOLD}${GREEN}==> macOS VM Setup (Apple Virtualization Framework)${RESET}"
  echo ""

  if vm_exists "$VM_NAME"; then
    skip "VM '${VM_NAME}' already exists"
    info "To recreate: tart delete ${VM_NAME} && bash setup-vanilla-vm.sh --os macos --name ${VM_NAME}"
  else
    info "Creating macOS VM from latest IPSW restore image..."
    echo -e "  ${YELLOW}This downloads the full macOS installer (~13 GB). Please be patient.${RESET}"
    echo ""
    tart create "$VM_NAME" \
      --from-ipsw=latest \
      --disk-size "$VM_DISK_GB"

    tart set "$VM_NAME" \
      --cpu "$VM_CPUS" \
      --memory "$VM_MEMORY_MB"

    ok "VM created: ${VM_NAME} (${VM_CPUS} CPUs, $((VM_MEMORY_MB / 1024))GB RAM, ${VM_DISK_GB}GB disk)"
  fi

  echo ""
  echo -e "${BOLD}${GREEN}==> Setup complete!${RESET}"
  echo ""
  echo -e "  VM name      : ${CYAN}${VM_NAME}${RESET}"
  echo -e "  Start VM     : ${CYAN}tart run ${VM_NAME} 2>/dev/null & disown${RESET}"
  echo ""
  echo -e "  ${YELLOW}First boot:${RESET} macOS Setup Assistant will guide you through"
  echo -e "  creating your user account, language, and other settings."
  echo ""
  echo -e "  ${YELLOW}Networking:${RESET} NAT — guest has internet automatically."
  echo -e "  ${YELLOW}Get guest IP:${RESET} tart ip ${VM_NAME}"
  echo ""
  echo -e "  ${YELLOW}SSH access${RESET} (after enabling Remote Login in System Settings):"
  echo "    ssh <your-user>@\$(tart ip ${VM_NAME})"
  echo ""
  echo -e "  ${YELLOW}Clipboard & display:${RESET} Handled natively by Virtualization.framework."
  echo -e "  No extra tools needed — copy/paste and dynamic resolution work out of the box."

  exit 0
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Ubuntu VM
# ══════════════════════════════════════════════════════════════════════════════

UBUNTU_VERSION_NODOT="${UBUNTU_VERSION//.}"

if [[ -n "$CLI_VM_NAME" ]]; then
  VM_NAME="$CLI_VM_NAME"
else
  VM_NAME="ubuntu-${UBUNTU_VERSION_NODOT}"
fi
VM_CPUS=6
VM_MEMORY_MB=8192
VM_DISK_GB=80

VARIANT="server"
if [[ "$INSTALL_DESKTOP" == true ]]; then
  VARIANT="desktop"
fi

UMODE="official ISO (Subiquity autoinstall)"
[[ "$USE_TART_BASE_IMAGES" == true ]] && UMODE="Tart OCI (ghcr.io/cirruslabs/ubuntu)"

echo ""
echo -e "${BOLD}${GREEN}==> Ubuntu ${UBUNTU_VERSION} — ${VARIANT} — ${UMODE}${RESET}"
echo ""

VM_JUST_CREATED=false
if vm_exists "$VM_NAME"; then
  skip "VM '${VM_NAME}' already exists"
  _recreate="tart delete ${VM_NAME} && bash setup-vanilla-vm.sh --os ubuntu --version ${UBUNTU_VERSION} --name ${VM_NAME}"
  [[ "$USE_TART_BASE_IMAGES" == true ]] && _recreate+=" --use-tart-base-images"
  if [[ "$INSTALL_DESKTOP" == true ]]; then
    _recreate+=" --gui"
  fi
  info "To recreate: ${_recreate}"
else
  if [[ "$USE_TART_BASE_IMAGES" == true ]]; then
    info "Cloning Ubuntu ${UBUNTU_VERSION} from ghcr.io/cirruslabs/ubuntu:${UBUNTU_VERSION}..."
    tart clone "ghcr.io/cirruslabs/ubuntu:${UBUNTU_VERSION}" "$VM_NAME"
    tart set "$VM_NAME" \
      --cpu "$VM_CPUS" \
      --memory "$VM_MEMORY_MB" \
      --disk-size "$VM_DISK_GB"
  else
    USE_ISO_INSTALL=true
    if ! iso_install_ubuntu_vm; then
      exit 1
    fi
  fi
  ok "VM created: ${VM_NAME} (${VM_CPUS} CPUs, $((VM_MEMORY_MB / 1024))GB RAM, ${VM_DISK_GB}GB disk)"
  VM_JUST_CREATED=true
fi

# ── Install SPICE tools and optionally desktop via SSH ────────────────────────
echo ""
info "Preparing first-boot provisioning script..."

PROVISION_SCRIPT="${HOME}/.local/share/vms/${VM_NAME}-provision.sh"
mkdir -p "$(dirname "$PROVISION_SCRIPT")"

APT_EXTRA_PACKAGES=""
DESKTOP_SYSTEMD_BLOCK=""
if [[ "$INSTALL_DESKTOP" == true ]]; then
  # Determine display manager for chosen desktop package
  case "$DESKTOP_PACKAGE" in
    ubuntu-desktop)  DISPLAY_MANAGER="gdm3" ;;
    xubuntu-desktop) DISPLAY_MANAGER="lightdm" ;;
    lubuntu-desktop) DISPLAY_MANAGER="sddm" ;;
    lightdm)         DISPLAY_MANAGER="lightdm" ;;
  esac
  if [[ "$USE_ISO_INSTALL" == true ]]; then
    APT_EXTRA_PACKAGES=""
    if [[ "$DESKTOP_PACKAGE" != "ubuntu-desktop" ]]; then
      # ISO is ubuntu-desktop; install chosen desktop on top
      APT_EXTRA_PACKAGES="${DESKTOP_PACKAGE} ${DISPLAY_MANAGER}"
    fi
    DESKTOP_SYSTEMD_BLOCK="
echo \">>> Desktop: ensuring graphical target + ${DISPLAY_MANAGER}...\"
sudo systemctl set-default graphical.target
sudo systemctl enable ${DISPLAY_MANAGER} 2>/dev/null || true"
  else
    APT_EXTRA_PACKAGES="${DESKTOP_PACKAGE} ${DISPLAY_MANAGER}"
    DESKTOP_SYSTEMD_BLOCK="
echo \">>> Configuring graphical login (${DISPLAY_MANAGER})...\"
sudo systemctl set-default graphical.target
sudo systemctl enable ${DISPLAY_MANAGER}"
  fi
fi

APT_CACHE_FIX=""
if [[ "$UBUNTU_VERSION" == "24.04" ]]; then
  APT_CACHE_FIX='
# Fix for Ubuntu 24.04 (Noble) ARM64: remove stale/empty apt cache files that
# prevent apt from resolving dependencies for security-updated packages.
echo ">>> Removing stale apt cache files for noble-updates/noble-security..."
sudo rm -f \
  /var/lib/apt/lists/ports.ubuntu.com_ubuntu-ports_dists_noble-updates_main_binary-arm64_Packages \
  /var/lib/apt/lists/ports.ubuntu.com_ubuntu-ports_dists_noble-security_main_binary-arm64_Packages'
fi

cat > "$PROVISION_SCRIPT" <<PROVISION
#!/usr/bin/env bash
set -euo pipefail
trap 'echo \$? > /tmp/provision-exit; touch /tmp/provision-done' EXIT

export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true
export NEEDRESTART_MODE=l
export LC_ALL=C.UTF-8
export LANG=C.UTF-8

# Ensure debconf stays non-interactive even under sudo (which strips env).
echo 'debconf debconf/frontend select Noninteractive' | sudo debconf-set-selections

# Avoid competing with first-boot unattended-upgrades / apt timers.
wait_for_dpkg_lock() {
  local n=0 busy
  while true; do
    busy=0
    if command -v fuser >/dev/null 2>&1; then
      sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 && busy=1
      sudo fuser /var/lib/dpkg/lock >/dev/null 2>&1 && busy=1
    fi
    pgrep -x apt-get >/dev/null && busy=1
    pgrep -x dpkg >/dev/null && busy=1
    pgrep -f unattended-upgrade >/dev/null && busy=1
    if [[ "\$busy" -eq 0 ]]; then
      return 0
    fi
    echo ">>> Waiting for apt/dpkg lock (unattended-upgrades or another apt)..."
    sleep 5
    n=\$((n + 1))
    if [[ \$n -gt 120 ]]; then
      echo ">>> Timed out waiting for package manager lock"
      exit 1
    fi
  done
}

sudo systemctl stop unattended-upgrades.service 2>/dev/null || true
sudo systemctl stop apt-daily.service 2>/dev/null || true
sudo systemctl stop apt-daily-upgrade.service 2>/dev/null || true
sudo systemctl stop apt-daily.timer 2>/dev/null || true
sudo systemctl stop apt-daily-upgrade.timer 2>/dev/null || true

wait_for_dpkg_lock

${APT_CACHE_FIX}

echo ">>> Updating package lists..."
sudo -E apt-get update -y --fix-missing

wait_for_dpkg_lock

echo ">>> Installing apt-fast for parallel downloads..."
sudo -E apt-get install -y software-properties-common
sudo -E add-apt-repository -y ppa:apt-fast/stable
sudo -E apt-get update -y
sudo -E apt-get install -y apt-fast

wait_for_dpkg_lock

echo ">>> Installing packages (SPICE tools${INSTALL_DESKTOP:+, desktop extras — may take a while})..."
APT_OPTS=(-y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold")
if [[ -n "${APT_EXTRA_PACKAGES}" ]]; then
  sudo -E apt-fast install "\${APT_OPTS[@]}" spice-vdagent spice-webdavd curl wget git ${APT_EXTRA_PACKAGES}
else
  sudo -E apt-fast install "\${APT_OPTS[@]}" spice-vdagent spice-webdavd curl wget git
fi

# Socket-activated or SysV-wrapped units: do not systemctl enable blindly.
sudo systemctl start spice-vdagent.socket 2>/dev/null || true
sudo systemctl start spice-vdagent.service 2>/dev/null || true
${DESKTOP_SYSTEMD_BLOCK}

echo ""
echo ">>> Provisioning complete!"
PROVISION

chmod +x "$PROVISION_SCRIPT"
ok "Provisioning script: $PROVISION_SCRIPT"

# ── Auto-provision new VMs (headless run → SSH → shutdown) ───────────────────
if [[ "$VM_JUST_CREATED" == true ]]; then
  if ! command -v sshpass &>/dev/null; then
    info "Installing sshpass (non-interactive SSH password authentication)..."
    brew install sshpass
    ok "sshpass installed"
  else
    skip "sshpass already installed"
  fi

  echo ""
  start_vm_headless "$VM_NAME" "$VM_USER" "$VM_PASSWORD"
  VM_IP="$_VM_IP"
  TART_PID="$_VM_PID"

  info "Uploading provisioning script to guest..."
  sshpass -p "$VM_PASSWORD" scp "${SSH_OPTS[@]}" \
    "$PROVISION_SCRIPT" "${VM_USER}@${VM_IP}:/tmp/provision.sh"

  info "Running provisioning inside the guest (this may take a while)..."
  sshpass -p "$VM_PASSWORD" ssh "${SSH_OPTS[@]}" \
    "${VM_USER}@${VM_IP}" "nohup bash /tmp/provision.sh > /tmp/provision.log 2>&1 &"

  # Show a scrolling 15-line window of the provisioning log, refreshed every 3s.
  PROV_WIN=15
  PROV_DRAWN=0
  info "Streaming provisioning output (last ${PROV_WIN} lines)..."
  echo ""
  while true; do
    PROV_SNAPSHOT="$(sshpass -p "$VM_PASSWORD" ssh "${SSH_OPTS[@]}" \
      "${VM_USER}@${VM_IP}" "tail -n ${PROV_WIN} /tmp/provision.log 2>/dev/null" 2>/dev/null || true)"
    if [[ -n "$PROV_SNAPSHOT" ]]; then
      # Erase previously drawn lines.
      if [[ "$PROV_DRAWN" -gt 0 ]]; then
        printf '\033[%dA' "$PROV_DRAWN"   # move cursor up
        printf '\033[J'                     # clear from cursor to end
      fi
      # Print the snapshot and count lines actually drawn.
      printf '%s\n' "$PROV_SNAPSHOT"
      PROV_DRAWN="$(printf '%s\n' "$PROV_SNAPSHOT" | wc -l | tr -d ' ')"
    fi
    if sshpass -p "$VM_PASSWORD" ssh "${SSH_OPTS[@]}" \
         "${VM_USER}@${VM_IP}" "test -f /tmp/provision-done" 2>/dev/null; then
      break
    fi
    sleep 3
  done
  PROV_EXIT=$(sshpass -p "$VM_PASSWORD" ssh "${SSH_OPTS[@]}" \
    "${VM_USER}@${VM_IP}" "cat /tmp/provision-exit 2>/dev/null || echo 1")
  if [[ "$PROV_EXIT" -ne 0 ]]; then
    err "Provisioning failed (exit code $PROV_EXIT) — see log above"
    exit 1
  fi

  stop_vm "$VM_USER" "$VM_PASSWORD" "$VM_IP" "$TART_PID"
  ok "VM stopped after provisioning"
fi

if [[ "$COPY_SSH_AFTER_CREATE" == true ]]; then
  echo ""
  info "Copying host SSH configuration into '${VM_NAME}'..."
  copy_ssh_config_from_host "$VM_NAME"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}==> Setup complete!${RESET}"
echo ""
echo -e "  VM name      : ${CYAN}${VM_NAME}${RESET}"
echo -e "  Guest user   : ${VM_USER} / ${VM_PASSWORD}"
if [[ "$INSTALL_DESKTOP" == true ]]; then
  echo -e "  Start VM     : ${CYAN}tart run ${VM_NAME} 2>/dev/null & disown${RESET}"
else
  echo -e "  Start VM     : ${CYAN}tart run ${VM_NAME} --no-graphics 2>/dev/null & disown${RESET}"
fi
echo ""
echo -e "  ${YELLOW}Networking:${RESET} NAT — guest has internet automatically."
echo -e "  ${YELLOW}Get guest IP:${RESET} tart ip ${VM_NAME}"
echo ""
echo -e "  ${YELLOW}SSH access:${RESET} ${YELLOW}(install sshpass if needed: brew install sshpass)${RESET}"
echo "    sshpass -p '${VM_PASSWORD}' ssh -o StrictHostKeyChecking=no ${VM_USER}@\$(tart ip ${VM_NAME})"
echo ""

if [[ "$VM_JUST_CREATED" == true ]]; then
  echo -e "  ${YELLOW}Provisioning:${RESET} completed automatically (SPICE tools${INSTALL_DESKTOP:+, Ubuntu Desktop})."
  if [[ "$INSTALL_DESKTOP" == true ]]; then
    echo ""
    echo -e "  ${YELLOW}Desktop:${RESET} start the VM with ${CYAN}tart run ${VM_NAME} 2>/dev/null & disown${RESET} and log in at the graphical prompt."
  fi
else
  echo -e "  ${YELLOW}Provision (install SPICE tools${INSTALL_DESKTOP:+, desktop}):${RESET}"
  echo "    sshpass -p '${VM_PASSWORD}' ssh -o StrictHostKeyChecking=no ${VM_USER}@\$(tart ip ${VM_NAME}) < \"${PROVISION_SCRIPT}\""
  if [[ "$INSTALL_DESKTOP" == true ]]; then
    echo ""
    echo -e "  After provisioning, reboot the VM for the graphical login:"
    echo "    sshpass -p '${VM_PASSWORD}' ssh -o StrictHostKeyChecking=no ${VM_USER}@\$(tart ip ${VM_NAME}) sudo reboot"
  fi
fi

# for macos guest vms, use the following commands to copy the SSH keys to the VM:
# VM_IP=$(tart ip dev-mac)
# ssh-copy-id <your-user>@$VM_IP            # bootstrap key auth
# scp -r ~/.ssh/id_* <your-user>@$VM_IP:~/.ssh/


