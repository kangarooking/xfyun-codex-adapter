#!/usr/bin/env bash
set -euo pipefail

LABEL="com.kangarooking.xfyun-codex-adapter"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
ADAPTER="$HOME/.cc-switch/xfyun_codex_adapter.py"
DB="$HOME/.cc-switch/cc-switch.db"
PROVIDER_ID="xfyun-astron-adapter"

launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
rm -f "$PLIST" "$ADAPTER"

if [[ -f "$DB" ]] && command -v sqlite3 >/dev/null 2>&1; then
  python3 <<'PYUNINSTALL' || true
import json
import os
from pathlib import Path
import sqlite3

provider_id = "xfyun-astron-adapter"
app_type = "codex"
db = Path.home() / ".cc-switch" / "cc-switch.db"
settings_path = Path.home() / ".cc-switch" / "settings.json"
codex_dir = Path.home() / ".codex"
config_path = codex_dir / "config.toml"
auth_path = codex_dir / "auth.json"


def read_json(path, default):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return default


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


con = sqlite3.connect(db)
local_settings = read_json(settings_path, {})
current = local_settings.get("currentProviderCodex") or local_settings.get("current_provider_codex")
if not current:
    row = con.execute(
        "select id from providers where app_type=? and is_current=1 limit 1",
        (app_type,),
    ).fetchone()
    current = row[0] if row else None

fallback = None
if current == provider_id:
    row = con.execute(
        "select id, settings_config from providers where app_type=? and id<>? order by sort_index, id limit 1",
        (app_type, provider_id),
    ).fetchone()
    if row:
        fallback = row[0]
        try:
            settings = json.loads(row[1] or "{}")
        except json.JSONDecodeError:
            settings = {}
        auth = settings.get("auth")
        config = settings.get("config")
        if isinstance(config, str):
            codex_dir.mkdir(parents=True, exist_ok=True)
            config_path.write_text(config, encoding="utf-8")
        if isinstance(auth, dict):
            write_json(auth_path, auth)
        local_settings["currentProviderCodex"] = fallback
        local_settings.pop("current_provider_codex", None)
        write_json(settings_path, local_settings)
        con.execute("update providers set is_current=0 where app_type=?", (app_type,))
        con.execute(
            "update providers set is_current=1 where app_type=? and id=?",
            (app_type, fallback),
        )

con.execute(
    "delete from provider_endpoints where app_type=? and provider_id=?",
    (app_type, provider_id),
)
con.execute(
    "delete from providers where app_type=? and id=?",
    (app_type, provider_id),
)
con.commit()
con.close()
if fallback:
    print(f"Switched Codex back to provider: {fallback}")
PYUNINSTALL
fi

echo "Uninstalled Xunfei Astron Adapter."
