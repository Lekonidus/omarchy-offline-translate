#!/bin/bash
# Runs the helper tests with the plugin's venv (created by `bin/offline-translate setup`).
set -euo pipefail
cd "$(dirname "$0")/.."
PY="${XDG_DATA_HOME:-$HOME/.local/share}/omarchy-offline-translate/venv/bin/python"
[[ -x $PY ]] || { echo "Run bin/offline-translate setup first"; exit 1; }
"$PY" -m unittest -v tests/test_offline_translate.py
omarchy plugin validate . 2>/dev/null || command -v omarchy >/dev/null || true
