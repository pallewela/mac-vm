#!/usr/bin/env bash
#
# push-tart-vm.sh — Push a local Tart VM to ghcr.io as an OCI image
#
# Usage:
#   bash push-tart-vm.sh <vm-name>                      # push as ghcr.io/pallewela/<vm-name>:latest
#   bash push-tart-vm.sh <vm-name> --tag v1.0           # push as ghcr.io/pallewela/<vm-name>:v1.0
#   bash push-tart-vm.sh <vm-name> --repo my-images     # push as ghcr.io/pallewela/my-images:latest
#   bash push-tart-vm.sh <vm-name> --tag v1.0 --repo my-images
#
# Prerequisites:
#   - tart (cirruslabs/cli/tart)
#   - A GitHub Personal Access Token with write:packages scope,
#     stored in GITHUB_TOKEN env var or passed via --token
#
set -euo pipefail

REGISTRY="ghcr.io"
NAMESPACE="pallewela"

# ── Colors ───────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  BOLD='\033[1m' GREEN='\033[0;32m' YELLOW='\033[0;33m'
  RED='\033[0;31m' CYAN='\033[0;36m' RESET='\033[0m'
else
  BOLD='' GREEN='' YELLOW='' RED='' CYAN='' RESET=''
fi

info()  { echo -e "${BOLD}${CYAN}==> $1${RESET}"; }
ok()    { echo -e "  ${GREEN}[ok]${RESET} $1"; }
err()   { echo -e "  ${RED}[error]${RESET} $1" >&2; }

usage() {
  echo "Usage: push-tart-vm.sh <vm-name> [options]"
  echo ""
  echo "Options:"
  echo "  --tag <tag>       Image tag (default: latest)"
  echo "  --repo <name>     Remote repository name (default: same as vm-name)"
  echo "  --token <token>   GitHub PAT (default: reads GITHUB_TOKEN env var)"
  echo "  --help            Show this help message"
}

# ── Parse args ───────────────────────────────────────────────────────────────
VM_NAME=""
TAG="latest"
REPO_NAME=""
TOKEN="${GITHUB_TOKEN:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --tag)
      shift; TAG="${1:-}"
      [[ -z "$TAG" ]] && { err "--tag requires a value"; exit 1; }
      ;;
    --repo)
      shift; REPO_NAME="${1:-}"
      [[ -z "$REPO_NAME" ]] && { err "--repo requires a value"; exit 1; }
      ;;
    --token)
      shift; TOKEN="${1:-}"
      [[ -z "$TOKEN" ]] && { err "--token requires a value"; exit 1; }
      ;;
    -*)
      err "Unknown option: $1"; usage >&2; exit 1 ;;
    *)
      if [[ -z "$VM_NAME" ]]; then
        VM_NAME="$1"
      else
        err "Unexpected argument: $1"; usage >&2; exit 1
      fi
      ;;
  esac
  shift
done

if [[ -z "$VM_NAME" ]]; then
  err "VM name is required"
  usage >&2
  exit 1
fi

REPO_NAME="${REPO_NAME:-$VM_NAME}"
REMOTE_REF="${REGISTRY}/${NAMESPACE}/${REPO_NAME}:${TAG}"

# ── Validate ─────────────────────────────────────────────────────────────────
if ! command -v tart &>/dev/null; then
  err "tart is not installed. Install with: brew install cirruslabs/cli/tart"
  exit 1
fi

if ! tart list -q 2>/dev/null | grep -qx "$VM_NAME"; then
  err "VM '${VM_NAME}' does not exist locally."
  echo "  Available VMs:"
  tart list -q 2>/dev/null | sed 's/^/    /'
  exit 1
fi

if tart list 2>/dev/null | awk -v n="$VM_NAME" '$2 == n { print $NF }' | grep -qx "running"; then
  err "VM '${VM_NAME}' is currently running. Stop it first: tart stop ${VM_NAME}"
  exit 1
fi

# ── Authenticate ─────────────────────────────────────────────────────────────
info "Authenticating with ${REGISTRY}..."
if [[ -z "$TOKEN" ]]; then
  echo -e "  ${YELLOW}No GITHUB_TOKEN set and no --token provided.${RESET}"
  echo -e "  Enter a GitHub PAT with ${CYAN}write:packages${RESET} scope:"
  read -rsp "  Token: " TOKEN
  echo ""
  [[ -z "$TOKEN" ]] && { err "Token cannot be empty"; exit 1; }
fi

echo "$TOKEN" | tart login "$REGISTRY" --username "$NAMESPACE" --password-stdin
ok "Logged in to ${REGISTRY}"

# ── Push ─────────────────────────────────────────────────────────────────────
info "Pushing '${VM_NAME}' -> ${REMOTE_REF}"
echo -e "  ${YELLOW}This may take a while for large VMs...${RESET}"

tart push "$VM_NAME" "$REMOTE_REF" --chunk-size 3

ok "Pushed ${REMOTE_REF}"

echo ""
echo -e "${BOLD}${GREEN}==> Push complete!${RESET}"
echo ""
echo -e "  Remote image : ${CYAN}${REMOTE_REF}${RESET}"
echo -e "  Pull command : ${CYAN}tart clone ${REMOTE_REF} ${VM_NAME}${RESET}"
echo ""
echo -e "  ${YELLOW}Note:${RESET} ghcr.io packages are private by default."
echo -e "  To make public: https://github.com/users/${NAMESPACE}/packages/container/${REPO_NAME}/settings"
