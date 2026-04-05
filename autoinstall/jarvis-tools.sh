#!/bin/bash
# J.A.R.V.I.S-OS Tools — Terminal-Wrapper (Git Bash / WSL / Linux)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

run_build() {
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$SCRIPT_DIR/build-iso.ps1" "$@"
}

run_copy() {
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$SCRIPT_DIR/copy-iso-to-ventoy.ps1" "$@"
}

run_build_copy() {
  local drive="${1:?Fehler: Laufwerksbuchstabe fehlt. Beispiel: jarvis-tools.sh build-copy D}"
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$SCRIPT_DIR/build-iso.ps1" -CopyToVentoy "$drive"
}

show_help() {
  echo ""
  echo "  J.A.R.V.I.S-OS Tools -- Proxmox ISO Verwaltung"
  echo ""
  echo "  Verwendung:"
  echo "    ./jarvis-tools.sh build          ISO bauen via WSL2"
  echo "    ./jarvis-tools.sh copy           ISO auf Ventoy-Stick kopieren"
  echo "    ./jarvis-tools.sh build-copy D   ISO bauen + direkt auf Stick D"
  echo "    ./jarvis-tools.sh help           Diese Hilfe"
  echo ""
}

case "${1:-help}" in
  build)      shift; run_build "$@" ;;
  copy)       shift; run_copy "$@" ;;
  build-copy) shift; run_build_copy "$@" ;;
  help|*)     show_help ;;
esac
