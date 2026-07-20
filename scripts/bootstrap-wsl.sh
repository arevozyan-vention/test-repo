#!/usr/bin/env bash
# from-nothing bootstrap for Windows + WSL2 (Ubuntu): installs missing tooling, then brings the stack up
set -euo pipefail

YES=0
DRY=0
for a in "$@"; do
  case "$a" in
    --yes) YES=1 ;;
    --dry-run) DRY=1 ;;
    *) echo "usage: $0 [--yes] [--dry-run]"; exit 1 ;;
  esac
done

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$0")/.."

have() { command -v "$1" >/dev/null 2>&1; }
docker_ok() { docker info >/dev/null 2>&1; }
row() { printf "  %-3s %-12s %s\n" "$1" "$2" "$3"; }
tf_min_ok() {
  local v; v=$(terraform version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
  [ "${v%%.*}" -gt 1 ] 2>/dev/null || { [ "${v%%.*}" -eq 1 ] && [ "${v#*.}" -ge 9 ]; } 2>/dev/null
}

if ! grep -qi microsoft /proc/version; then
  echo "This script is meant for WSL2. On plain Linux it mostly works, but review it first."
fi

if [ "$(ps -p 1 -o comm=)" != "systemd" ]; then
  echo "systemd is not running. Enable it first:"
  echo "  printf '[boot]\nsystemd=true\n' | sudo tee /etc/wsl.conf"
  echo "  then run 'wsl --shutdown' in PowerShell and reopen Ubuntu"
  exit 1
fi

INSTALL=()
NOTES=()

echo "Checking environment:"

START_DOCKER=0
if have docker && docker_ok; then
  row ok docker "daemon running"
elif systemctl list-unit-files docker.service --no-legend 2>/dev/null | grep -q docker; then
  row -- docker "engine installed but not running"
  START_DOCKER=1
  NOTES+=("  ! docker engine is installed but not running, it will be started; if you were")
  NOTES+=("    just added to the docker group, reopen the terminal and re-run this script")
else
  row -- docker "no engine found"
  INSTALL+=(docker)
  NOTES+=("  * docker engine  native engine inside WSL from the official docker apt repo")
fi

for t in k3d kubectl terraform task mkcert; do
  if [ "$t" = terraform ] && have terraform && ! tf_min_ok; then
    row -- terraform "too old, need >= 1.9"
    INSTALL+=(terraform)
  elif have "$t"; then
    row ok "$t" "installed"
  else
    row -- "$t" "NOT found"
    INSTALL+=("$t")
  fi
done

for item in "${INSTALL[@]:-}"; do
  case "$item" in
    k3d) NOTES+=("  * k3d            via the official install script") ;;
    kubectl) NOTES+=("  * kubectl        latest stable from dl.k8s.io") ;;
    terraform) NOTES+=("  * terraform      via the hashicorp apt repository") ;;
    task) NOTES+=("  * go-task        via the official install script") ;;
    mkcert) NOTES+=("  * mkcert         via apt (plus libnss3-tools for browser trust)") ;;
  esac
done
NOTES+=("  * mkcert CA      trusted by the Linux store during 'task up' AND by the Windows")
NOTES+=("                   cert store via certutil.exe, so your Windows browser trusts")
NOTES+=("                   https://*.localhost (a Windows confirmation dialog will pop up)")

echo
if [ ${#INSTALL[@]} -eq 0 ]; then
  echo "Everything is already installed."
else
  echo "The following will be installed:"
fi
printf '%s\n' "${NOTES[@]}"
echo
echo "Then 'task up' will create the k3d cluster and deploy the whole stack (~10 GB of images on first run)."

if [ "$DRY" -eq 1 ]; then
  echo
  echo "Dry run, nothing was changed."
  exit 0
fi

if [ "$YES" -ne 1 ]; then
  echo
  read -r -p "Proceed? [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || { echo "Aborted, nothing was changed."; exit 0; }
fi

sudo -v
sudo apt-get update -qq

for item in "${INSTALL[@]:-}"; do
  case "$item" in
    docker)
      sudo install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo tee /etc/apt/keyrings/docker.asc >/dev/null
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
      sudo apt-get update -qq
      sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io
      sudo systemctl enable --now docker
      # stale cli shims must not shadow the real client
      if [ "$(command -v docker)" != "/usr/bin/docker" ] && [ -e /usr/local/bin/docker ]; then
        sudo rm -f /usr/local/bin/docker
        hash -r
      fi
      sudo usermod -aG docker "$USER"
      if ! docker_ok; then
        # a running shell can't pick up the fresh group, sg can
        if sg docker -c 'docker info' >/dev/null 2>&1; then
          echo "Continuing under the docker group, no relogin needed..."
          exec sg docker -c "$SELF --yes"
        fi
        echo
        echo "Docker is installed but your shell doesn't have the docker group yet."
        echo "Log out and back in (or run 'wsl --shutdown' in PowerShell), then re-run this script."
        exit 0
      fi
      ;;
    k3d) curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | sudo bash ;;
    kubectl)
      curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/$(dpkg --print-architecture)/kubectl"
      sudo install /tmp/kubectl /usr/local/bin/kubectl && rm /tmp/kubectl
      ;;
    terraform)
      sudo apt-get install -y -qq gnupg software-properties-common
      curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp.gpg
      echo "deb [signed-by=/usr/share/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
      sudo apt-get update -qq && sudo apt-get install -y -qq terraform
      ;;
    task) curl -fsSL https://taskfile.dev/install.sh | sudo sh -s -- -d -b /usr/local/bin ;;
    mkcert) sudo apt-get install -y -qq mkcert libnss3-tools ;;
    "") ;;
  esac
done

if [ "$START_DOCKER" -eq 1 ]; then
  sudo systemctl enable --now docker
  if ! docker_ok; then
    echo
    echo "Docker engine is running but your user can't reach it (docker group missing?)."
    echo "Run: sudo usermod -aG docker \$USER, then 'wsl --shutdown' in PowerShell and re-run this script."
    exit 0
  fi
fi

task up

# windows browsers look at the windows cert store, not the wsl one
if grep -qi microsoft /proc/version && have certutil.exe; then
  certutil.exe -user -addstore Root "$(wslpath -w "$(mkcert -CAROOT)/rootCA.pem")" || \
    echo "Could not import the CA into the Windows store, run manually: certutil.exe -user -addstore Root \"\$(wslpath -w \"\$(mkcert -CAROOT)/rootCA.pem\")\""
fi

echo
echo "Waiting for all argocd applications to become healthy"
echo "(first run pulls ~10 GB of images, this can take 15-30 minutes)..."
for i in $(seq 1 120); do
  total=$(kubectl get applications -n argocd --no-headers 2>/dev/null | wc -l | tr -d ' ')
  unhealthy=$(kubectl get applications -n argocd -o jsonpath='{.items[*].status.health.status}' 2>/dev/null | tr ' ' '\n' | grep -vc '^Healthy$' || true)
  if [ "${total:-0}" -ge 5 ] && [ "${unhealthy:-1}" -eq 0 ]; then break; fi
  sleep 15
done

ARGOCD_PW=$(kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "<see: kubectl get secret argocd-initial-admin-secret -n argocd>")
GRAFANA_PW=$(kubectl get secret grafana-admin -n monitoring -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d || echo "<see: kubectl get secret grafana-admin -n monitoring>")

echo
echo "Done. Entry points and credentials (opening in your Windows browser):"
echo "  Bookinfo   https://bookinfo.localhost/productpage   no login"
echo "  Grafana    https://grafana.localhost                admin / $GRAFANA_PW"
echo "  Argo CD    https://argocd.localhost                 admin / $ARGOCD_PW"
echo

# no -k on purpose: passes only once the real cert is served AND the ca is trusted
for url in "https://bookinfo.localhost/productpage" "https://grafana.localhost" "https://argocd.localhost"; do
  ok=0
  for i in $(seq 1 60); do
    code=$(curl -s -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)
    case "$code" in 2*|3*) ok=1; break ;; esac
    sleep 2
  done
  [ "$ok" -eq 1 ] || echo "warning: $url did not pass the tls check yet"
done

if have powershell.exe; then
  echo "Opening browser tabs..."
  for url in "https://bookinfo.localhost/productpage" "https://grafana.localhost" "https://argocd.localhost"; do
    powershell.exe -NoProfile -Command "Start-Process '$url'" >/dev/null 2>&1 || echo "could not open $url, open it manually"
  done
fi
