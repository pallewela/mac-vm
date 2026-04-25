#!/usr/bin/env bash
#
# setup-vanilla-vm.sh — Create Ubuntu VMs from Tart OCI images via Apple VZ
#
# Prerequisites installed via Homebrew:
#   - tart (cirruslabs/cli/tart) — CLI for Apple's Virtualization.framework
#     Supports Linux (OCI) guests on Apple Silicon.
#
# Usage:
#   bash setup-vanilla-vm.sh                # Ubuntu 24.04 from ghcr.io OCI
#   bash setup-vanilla-vm.sh --version 22.04
#   bash setup-vanilla-vm.sh --gui                    # ubuntu-desktop (default)
#   bash setup-vanilla-vm.sh --gui xubuntu-desktop
#   bash setup-vanilla-vm.sh --version-list
#   bash setup-vanilla-vm.sh --name my-vm
#   bash setup-vanilla-vm.sh --docker-setup my-vm
#   bash setup-vanilla-vm.sh --ssh-config-from-host my-vm
#   bash setup-vanilla-vm.sh --name my-vm --ssh-config-from-host
#   bash setup-vanilla-vm.sh --verbose                  # show detailed output
#   bash setup-vanilla-vm.sh --log /tmp/vm-setup.log   # tee all output to a file
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
#
set -euo pipefail

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
  echo "Usage: setup-vanilla-vm.sh [--version <ver>] [--name <vm-name>] [--gui] [--ssh-config-from-host]"
  echo "       setup-vanilla-vm.sh --docker-setup <vm-name>"
  echo "       setup-vanilla-vm.sh --ssh-config-from-host <vm-name>"
  echo "       setup-vanilla-vm.sh --version-list"
  echo ""
  echo "Options:"
  echo "  --version <ver>               Ubuntu version (default: 24.04)"
  echo "  --version-list                List available OCI Ubuntu release lines, then exit"
  echo "  --name <vm-name>              Custom VM name"
  echo "  --gui [desktop]               Install a desktop (ubuntu-desktop|xubuntu-desktop|lubuntu-desktop|lightdm)."
  echo "                                Default: ubuntu-desktop."
  echo "  --docker-setup <name>         Install Docker in an existing VM + configure host"
  echo "  --ssh-config-from-host [name] Copy host ~/.ssh/ keys (id_*, *.pem) into VM."
  echo "  --verbose                     Show detailed output (set -x, SSH debug, apt details)"
  echo "  --log <file>                  Tee all output (including provisioning) to a log file"
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

# ── Parse flags ────────────────────────────────────────────────────────────────
UBUNTU_VERSION="24.04"
VERSION_LIST=false
INSTALL_DESKTOP=false
DESKTOP_PACKAGE="ubuntu-desktop"
CLI_VM_NAME=""
DOCKER_SETUP_VM=""
COPY_SSH_VM=""
COPY_SSH_AFTER_CREATE=false
DEBUG_NO_HEADLESS=false
VERBOSE=false
LOG_FILE=""
OTHER_FLAGS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --version)
      OTHER_FLAGS=true
      shift
      UBUNTU_VERSION="${1:-}"
      if [[ -z "$UBUNTU_VERSION" ]]; then
        err "--version requires a value (e.g. 22.04, 24.04)"; exit 1
      fi
      ;;
    --version-list)
      VERSION_LIST=true
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
    --verbose)
      VERBOSE=true
      ;;
    --log)
      shift
      LOG_FILE="${1:-}"
      if [[ -z "$LOG_FILE" ]]; then
        err "--log requires a file path"; exit 1
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

# ── --verbose: enable detailed output ─────────────────────────────────────────
if [[ "$VERBOSE" == true ]]; then
  set -x
  # Replace LogLevel=ERROR with LogLevel=INFO in SSH_OPTS
  SSH_OPTS=("${SSH_OPTS[@]/LogLevel=ERROR/LogLevel=INFO}")
fi

# ── --log: tee all output to a file ──────────────────────────────────────────
if [[ -n "$LOG_FILE" ]]; then
  LOG_DIR="$(dirname "$LOG_FILE")"
  mkdir -p "$LOG_DIR"
  exec > >(tee -a "$LOG_FILE") 2>&1
  info "Logging all output to: ${LOG_FILE}"
fi

# ── --version-list: OCI tags ─────────────────────────────────────────────────
if [[ "$VERSION_LIST" == true ]]; then
  info "Fetching OCI tags from ghcr.io/cirruslabs/ubuntu..."
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
  echo "Available Tart OCI images (ghcr.io/cirruslabs/ubuntu):"
  echo "$_tags" | while read -r v; do
    if [[ "$v" == "$UBUNTU_VERSION" ]]; then
      echo -e "  ${GREEN}${v}${RESET} (default)"
    else
      echo -e "  ${v}"
    fi
  done
  echo ""
  echo "Usage: bash setup-vanilla-vm.sh --version <ver>"
  exit 0
fi

if [[ -n "$DOCKER_SETUP_VM" && "$OTHER_FLAGS" == true ]]; then
  err "--docker-setup must be used on its own (no --gui or --name)"
  exit 1
fi

if [[ -n "$COPY_SSH_VM" ]]; then
  if [[ "$OTHER_FLAGS" == true || -n "$DOCKER_SETUP_VM" ]]; then
    err "--ssh-config-from-host <vm-name> must be used on its own (no --gui, --name, --docker-setup)"
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

echo ""
echo -e "${BOLD}${GREEN}==> Ubuntu ${UBUNTU_VERSION} — ${VARIANT} — Tart OCI (ghcr.io/cirruslabs/ubuntu)${RESET}"
echo ""

VM_JUST_CREATED=false
if vm_exists "$VM_NAME"; then
  skip "VM '${VM_NAME}' already exists"
  _recreate="tart delete ${VM_NAME} && bash setup-vanilla-vm.sh --version ${UBUNTU_VERSION} --name ${VM_NAME}"
  if [[ "$INSTALL_DESKTOP" == true ]]; then
    _recreate+=" --gui"
  fi
  info "To recreate: ${_recreate}"
else
  info "Cloning Ubuntu ${UBUNTU_VERSION} from ghcr.io/cirruslabs/ubuntu:${UBUNTU_VERSION}..."
  tart clone "ghcr.io/cirruslabs/ubuntu:${UBUNTU_VERSION}" "$VM_NAME"
  tart set "$VM_NAME" \
    --cpu "$VM_CPUS" \
    --memory "$VM_MEMORY_MB" \
    --disk-size "$VM_DISK_GB"
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
  case "$DESKTOP_PACKAGE" in
    ubuntu-desktop)  DISPLAY_MANAGER="gdm3" ;;
    xubuntu-desktop) DISPLAY_MANAGER="lightdm" ;;
    lubuntu-desktop) DISPLAY_MANAGER="sddm" ;;
    lightdm)         DISPLAY_MANAGER="lightdm" ;;
  esac
  APT_EXTRA_PACKAGES="${DESKTOP_PACKAGE} ${DISPLAY_MANAGER}"
  DESKTOP_SYSTEMD_BLOCK="
echo \">>> Configuring graphical login (${DISPLAY_MANAGER})...\"
sudo systemctl set-default graphical.target
sudo systemctl enable ${DISPLAY_MANAGER}"
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

VERBOSE_PROVISION=""
if [[ "$VERBOSE" == true ]]; then
  VERBOSE_PROVISION="set -x"
fi

cat > "$PROVISION_SCRIPT" <<PROVISION
#!/usr/bin/env bash
set -euo pipefail
${VERBOSE_PROVISION}

# Persist a copy of all provisioning output inside the guest for later debugging.
sudo touch /var/log/provision.log
sudo chmod 666 /var/log/provision.log
exec > >(tee -a /var/log/provision.log) 2>&1

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
    "${VM_USER}@${VM_IP}" "bash /tmp/provision.sh"

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
