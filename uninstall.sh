#!/usr/bin/env bash
set -euo pipefail

LABEL="com.kangarooking.xfyun-codex-adapter"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
ADAPTER="$HOME/.cc-switch/xfyun_codex_adapter.py"
DB="$HOME/.cc-switch/cc-switch.db"
CODEX_CONFIG="$HOME/.codex/config.toml"
CODEX_AUTH="$HOME/.codex/auth.json"

launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
rm -f "$PLIST" "$ADAPTER"

if [[ -f "$DB" ]] && command -v sqlite3 >/dev/null 2>&1; then
  sqlite3 "$DB" "delete from provider_endpoints where app_type='codex' and provider_id='xfyun-astron-adapter'; delete from providers where app_type='codex' and id='xfyun-astron-adapter';" || true
fi

if [[ -f "$CODEX_CONFIG" ]] && grep -q 'model_provider = "xfyun_astron_adapter"' "$CODEX_CONFIG"; then
  latest_config_backup="$(ls -t "$CODEX_CONFIG".bak.xfyun-adapter-* 2>/dev/null | head -n 1 || true)"
  latest_auth_backup="$(ls -t "$CODEX_AUTH".bak.xfyun-adapter-* 2>/dev/null | head -n 1 || true)"

  if [[ -n "$latest_config_backup" ]]; then
    cp "$latest_config_backup" "$CODEX_CONFIG"
    echo "Restored Codex config from: $latest_config_backup"
  else
    echo "No Codex config backup found. Please switch Codex to another provider manually."
  fi

  if [[ -n "$latest_auth_backup" ]]; then
    cp "$latest_auth_backup" "$CODEX_AUTH"
    echo "Restored Codex auth from: $latest_auth_backup"
  fi
fi

echo "Uninstalled Xunfei Astron Adapter."
