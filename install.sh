#!/bin/bash
# One-liner installer for Warp Relay:
#   bash <(curl -fsSL https://raw.githubusercontent.com/BlackSysShark25/warp-relay/main/install.sh)
set -euo pipefail
REPO="https://raw.githubusercontent.com/BlackSysShark25/warp-relay/main"
[[ $EUID -ne 0 ]] && { echo "Run as root: sudo bash install.sh"; exit 1; }
command -v curl >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq curl; }
tmp=$(mktemp -d)
curl -fsSL "$REPO/relay.sh" -o "$tmp/relay.sh"
chmod +x "$tmp/relay.sh"
exec "$tmp/relay.sh" --setup
