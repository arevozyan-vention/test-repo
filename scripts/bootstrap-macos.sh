#!/usr/bin/env bash
# from-nothing bootstrap for macOS: installs missing tooling, then brings the stack up
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

cd "$(dirname "$0")/.."

have() { command -v "$1" >/dev/null 2>&1; }
docker_ok() { docker info >/dev/null 2>&1; }
row() { printf "  %-3s %-12s %s\n" "$1" "$2" "$3"; }

INSTALL=()
NOTES=()
NEED_RUNTIME=0

echo "Checking environment:"

if have brew; then
  row ok homebrew "$(brew --version | head -1)"
else
  row -- homebrew "NOT found"
  INSTALL+=(homebrew)
  NOTES+=("  * Homebrew      macOS package manager (asks for your sudo password)")
fi

if have docker && docker_ok; then
  row ok docker "daemon running, keeping it"
else
  NEED_RUNTIME=1
  if have colima; then
    row ok colima "installed, will be started"
  else
    row -- docker "no working daemon found"
    INSTALL+=(colima docker)
    NOTES+=("  * colima        docker runtime in a lightweight VM (4 CPU / 12 GB RAM / 40 GB disk)")
    NOTES+=("  * docker        the docker CLI client (talks to colima)")
  fi
fi

for t in k3d kubectl terraform task mkcert; do
  if have "$t"; then
    row ok "$t" "installed"
  else
    row -- "$t" "NOT found"
    INSTALL+=("$t")
  fi
done

TOOLS=$(printf '%s\n' "${INSTALL[@]:-}" | grep -vE '^(homebrew|colima|docker)$' | paste -sd, - | sed 's/,/, /g' || true)
[ -n "$TOOLS" ] && NOTES+=("  * $TOOLS  -- via brew")
NOTES+=("  * mkcert CA     root certificate trusted by the system and browsers,")
NOTES+=("                  installed later during 'task up' (asks for your sudo password)")

echo
if [ ${#INSTALL[@]} -eq 0 ]; then
  echo "Everything is already installed."
else
  echo "The following will be installed:"
  printf '%s\n' "${NOTES[@]}"
fi
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

for item in "${INSTALL[@]:-}"; do
  case "$item" in
    homebrew)
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      # brew lands outside PATH on a fresh shell
      if [ -x /opt/homebrew/bin/brew ]; then eval "$(/opt/homebrew/bin/brew shellenv)"; else eval "$(/usr/local/bin/brew shellenv)"; fi
      ;;
    task) brew install go-task ;;
    # terraform left homebrew core after the busl relicense, tap needs explicit trust since brew 4.6
    terraform)
      brew trust hashicorp/tap >/dev/null 2>&1 || true
      brew install hashicorp/tap/terraform
      ;;
    "") ;;
    *) brew install "$item" ;;
  esac
done

if [ "$NEED_RUNTIME" -eq 1 ]; then
  colima status >/dev/null 2>&1 || colima start --cpu 4 --memory 12 --disk 40
fi

task up

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
echo "Done. Entry points and credentials:"
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

echo "Opening browser tabs..."
for url in "https://bookinfo.localhost/productpage" "https://grafana.localhost" "https://argocd.localhost"; do
  open "$url" || echo "could not open $url, open it manually"
done
