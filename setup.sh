#!/usr/bin/env bash
#
# setup.sh - fresh Ubuntu 24.04 Desktop (x86_64, NVIDIA RTX) -> SSH + Docker + Isaac ROS (+ VNC)
#
# Usage (run as a regular user, NOT root; the script calls sudo itself):
#   ./setup.sh                 # all stages in order
#   ./setup.sh docker isaac    # selected stages only
#
# Stages:  base  driver  ssh  docker  isaac  vnc  verify
#
# Environment variables (optional):
#   HARDEN_SSH=1               disable password login (only if ~/.ssh/authorized_keys has a key)
#   VNC_PASSWORD=...           VNC password (otherwise you are prompted)
#   ISAAC_ROS_RELEASE=release-5.0   Isaac ROS apt repository branch
#   NVIDIA_DRIVER_PKG=...      force a specific driver package, e.g. nvidia-driver-595-open
#   FORCE=1                    run even on a system other than Ubuntu 24.04
#
# The script is idempotent: it is safe to run it repeatedly.

set -Eeuo pipefail

# ----------------------------------------------------------------- settings
MIN_DRIVER=595
ISAAC_ROS_RELEASE="${ISAAC_ROS_RELEASE:-release-5.0}"
HARDEN_SSH="${HARDEN_SSH:-0}"
VNC_PASSWORD="${VNC_PASSWORD:-}"
NVIDIA_DRIVER_PKG="${NVIDIA_DRIVER_PKG:-}"
FORCE="${FORCE:-0}"
ISAAC_WS="${HOME}/workspaces/isaac_ros-dev"

STAGES_ALL=(base driver ssh docker isaac vnc verify)
export DEBIAN_FRONTEND=noninteractive

# ------------------------------------------------------------------ output
info() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m OK\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m !!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERR\033[0m %s\n' "$*" >&2; exit 1; }

trap 'die "Failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

# ------------------------------------------------------------------ checks
preflight() {
  [[ $EUID -ne 0 ]] || die "Do not run as root. Run as a regular user; the script calls sudo itself."

  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "24.04" ]]; then
    [[ $FORCE == 1 ]] || die "Isaac ROS officially supports Ubuntu 24.04. This system is: ${PRETTY_NAME:-?}. (FORCE=1 overrides.)"
    warn "Unsupported system: ${PRETTY_NAME:-?}"
  fi
  [[ "$(uname -m)" == "x86_64" ]] || die "This script targets x86_64, found $(uname -m)."

  command -v lspci >/dev/null && ! lspci | grep -qi nvidia && warn "No NVIDIA GPU found (lspci)."

  info "Checking sudo"
  sudo -v
  # keep sudo credentials alive while the script runs
  ( while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) 2>/dev/null &
  SUDO_KEEPALIVE_PID=$!
  trap 'kill "${SUDO_KEEPALIVE_PID:-0}" 2>/dev/null || true' EXIT
}

apt_install() { sudo apt-get install -y "$@"; }

# -------------------------------------------------------------------- base
stage_base() {
  info "System update and base packages"
  sudo apt-get update
  sudo apt-get full-upgrade -y
  apt_install curl gnupg ca-certificates software-properties-common locales

  sudo locale-gen en_US en_US.UTF-8
  sudo update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
  sudo add-apt-repository -y universe
  sudo apt-get update
  ok "Base system ready"
}

# ------------------------------------------------------------------ driver
driver_major() {
  nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 | cut -d. -f1
}

pick_driver_pkg() {
  local n
  n=$(apt-cache pkgnames nvidia-driver- \
        | grep -E '^nvidia-driver-[0-9]+(-open)?$' \
        | sed -E 's/^nvidia-driver-([0-9]+).*/\1/' \
        | sort -un | awk -v m="$MIN_DRIVER" '$1 >= m' | tail -n1) || true
  [[ -n "$n" ]] || return 1
  if apt-cache show "nvidia-driver-${n}-open" >/dev/null 2>&1; then
    echo "nvidia-driver-${n}-open"
  else
    echo "nvidia-driver-${n}"
  fi
}

stage_driver() {
  info "NVIDIA driver (${MIN_DRIVER}+ required)"
  local cur; cur="$(driver_major || true)"
  if [[ -n "$cur" && "$cur" -ge "$MIN_DRIVER" ]]; then
    ok "Driver is already ${cur}.x, skipping"
    return
  fi

  local pkg="${NVIDIA_DRIVER_PKG:-}"
  [[ -n "$pkg" ]] || pkg="$(pick_driver_pkg)" \
    || die "No driver ${MIN_DRIVER}+ in apt. Try 'ubuntu-drivers list' and set NVIDIA_DRIVER_PKG."

  command -v mokutil >/dev/null && mokutil --sb-state 2>/dev/null | grep -qi enabled \
    && warn "Secure Boot is enabled: you may need to confirm MOK enrollment on reboot (blue screen)."

  info "Installing ${pkg}"
  apt_install "$pkg"
  DRIVER_REBOOT=1
}

# --------------------------------------------------------------------- ssh
stage_ssh() {
  info "SSH server and firewall"
  apt_install openssh-server ufw
  sudo systemctl enable --now ssh
  sudo ufw allow ssh
  sudo ufw --force enable

  if [[ $HARDEN_SSH == 1 ]]; then
    local ak="${HOME}/.ssh/authorized_keys"
    if [[ -s "$ak" ]]; then
      local conf=/etc/ssh/sshd_config.d/99-hardening.conf
      sudo tee "$conf" >/dev/null <<CONF
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
KbdInteractiveAuthentication no
MaxAuthTries 3
AllowUsers ${USER}
CONF
      if sudo sshd -t; then
        sudo systemctl reload ssh
        ok "SSH hardened (keys only, user ${USER})"
      else
        sudo rm -f "$conf"
        die "sshd -t failed, hardening rolled back."
      fi
    else
      warn "HARDEN_SSH=1 but ${ak} is empty/missing. First, from the client: ssh-copy-id ${USER}@$(hostname -I | awk '{print $1}')"
    fi
  else
    warn "SSH hardening is off. Once your key is copied: HARDEN_SSH=1 ./setup.sh ssh"
  fi
  ok "SSH is running, address: $(hostname -I | awk '{print $1}')"
}

# ------------------------------------------------------------------ docker
stage_docker() {
  info "Docker Engine"
  if ! command -v docker >/dev/null; then
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    # shellcheck disable=SC1091
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    sudo apt-get update
    apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  else
    ok "Docker is already installed"
  fi
  sudo systemctl enable --now docker

  info "NVIDIA Container Toolkit"
  local key=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  local url=https://nvidia.github.io/libnvidia-container
  curl -fsSL "${url}/gpgkey" | sudo gpg --batch --yes --dearmor -o "$key"
  curl -fsSL "${url}/stable/deb/nvidia-container-toolkit.list" \
    | sed "s#deb https://#deb [signed-by=${key}] https://#g" \
    | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
  sudo apt-get update
  apt_install nvidia-container-toolkit
  sudo nvidia-ctk runtime configure --runtime=docker
  sudo systemctl restart docker

  if ! id -nG "$USER" | grep -qw docker; then
    sudo usermod -aG docker "$USER"
    DOCKER_RELOGIN=1
  fi
  ok "Docker + NVIDIA toolkit done"
}

# ------------------------------------------------------------------- isaac
stage_isaac() {
  info "Isaac ROS (${ISAAC_ROS_RELEASE})"
  mkdir -p "${ISAAC_WS}/src"
  # shellcheck disable=SC2016  # intentionally single-quoted, expanded later by ~/.bashrc
  grep -q 'ISAAC_ROS_WS' "${HOME}/.bashrc" 2>/dev/null \
    || echo 'export ISAAC_ROS_WS="${ISAAC_ROS_WS:-${HOME}/workspaces/isaac_ros-dev/}"' >> "${HOME}/.bashrc"

  local key=/usr/share/keyrings/nvidia-isaac-ros.gpg
  curl -fsSL https://isaac.download.nvidia.com/isaac-ros/repos.key | sudo gpg --batch --yes --dearmor -o "$key"
  echo "deb [signed-by=${key}] https://isaac.download.nvidia.com/isaac-ros/${ISAAC_ROS_RELEASE} noble main" \
    | sudo tee /etc/apt/sources.list.d/nvidia-isaac-ros.list >/dev/null
  sudo apt-get update
  apt_install isaac-ros-cli
  sudo isaac-ros init docker
  ok "Isaac ROS CLI ready (workspace: ${ISAAC_WS})"
}

# --------------------------------------------------------------------- vnc
stage_vnc() {
  info "VNC (GNOME Remote Desktop)"
  apt_install gnome-remote-desktop

  if [[ ! "${XDG_SESSION_TYPE:-}" =~ ^(x11|wayland)$ ]]; then
    warn "Not in a graphical session (probably SSH), skipping VNC setup."
    warn "Run this in a terminal on the desktop itself: ./setup.sh vnc"
    return
  fi

  local pw="$VNC_PASSWORD"
  if [[ -z "$pw" && -t 0 ]]; then
    read -rsp "Choose a VNC password: " pw; echo
  fi
  [[ -n "$pw" ]] || { warn "No VNC password given, skipping (VNC_PASSWORD=... ./setup.sh vnc)."; return; }

  grdctl vnc enable
  grdctl vnc set-auth-method password
  grdctl vnc set-password "$pw"
  grdctl vnc disable-view-only
  systemctl --user enable --now gnome-remote-desktop.service
  grdctl status || true
  ok "VNC enabled. Do NOT open port 5900 in the firewall; connect through an SSH tunnel:"
  echo "    ssh -L 5900:localhost:5900 ${USER}@$(hostname -I | awk '{print $1}')   # then a VNC client to localhost:5900"
}

# ------------------------------------------------------------------ verify
stage_verify() {
  info "Verification"
  lsb_release -ds || true

  if nvidia-smi -L; then ok "GPU visible on the host"; else warn "nvidia-smi failed (reboot after the driver install?)"; fi

  if sudo docker run --rm --gpus all ubuntu:24.04 nvidia-smi -L; then
    ok "GPU visible inside Docker"
  else
    warn "GPU not working in Docker, check the NVIDIA Container Toolkit"
  fi
  if command -v isaac-ros >/dev/null; then ok "isaac-ros CLI installed"; else warn "isaac-ros CLI missing"; fi
}

# -------------------------------------------------------------------- main
DRIVER_REBOOT=0
DOCKER_RELOGIN=0

main() {
  local stages=("$@")
  [[ ${#stages[@]} -gt 0 && "${stages[0]}" != "all" ]] || stages=("${STAGES_ALL[@]}")

  for s in "${stages[@]}"; do
    declare -F "stage_${s}" >/dev/null || die "Unknown stage '${s}'. Available: ${STAGES_ALL[*]}"
  done

  preflight

  for s in "${stages[@]}"; do
    "stage_${s}"
    # a reboot is required after a driver install; later stages (GPU in Docker) would fail
    if [[ "$s" == driver && $DRIVER_REBOOT == 1 ]]; then
      warn "Driver installed. REBOOT (sudo reboot) and run the script again: ./setup.sh"
      exit 0
    fi
  done

  info "Done"
  [[ -f /var/run/reboot-required ]] && warn "The system recommends a reboot (sudo reboot)."
  [[ $DOCKER_RELOGIN == 1 ]] && warn "Log out and back in (or run 'newgrp docker') so docker works without sudo."
  echo "Start Isaac ROS with:  isaac-ros activate"
}

main "$@"
