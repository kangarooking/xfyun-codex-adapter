#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$HOME/.cc-switch"
LOG_DIR="$APP_DIR/logs"
ADAPTER="$APP_DIR/xfyun_codex_adapter.py"
PLIST="$HOME/Library/LaunchAgents/com.kangarooking.xfyun-codex-adapter.plist"
LABEL="com.kangarooking.xfyun-codex-adapter"
DB="$APP_DIR/cc-switch.db"
CODEX_DIR="$HOME/.codex"
PORT="18666"
BASE_URL="http://127.0.0.1:${PORT}/v1"
PROVIDER_ID="xfyun-astron-adapter"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This installer currently supports macOS only."
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required but was not found."
  exit 1
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "sqlite3 is required but was not found."
  exit 1
fi

API_KEY="${XFYUN_CODING_PLAN_API_KEY:-}"
if [[ -z "$API_KEY" ]]; then
  if [[ ! -r /dev/tty ]]; then
    echo "Cannot read API Key interactively. Please rerun with XFYUN_CODING_PLAN_API_KEY set."
    exit 1
  fi
  printf "Paste your Xfyun Coding Plan API Key: " > /dev/tty
  stty -echo < /dev/tty
  IFS= read -r API_KEY < /dev/tty
  stty echo < /dev/tty
  printf "\n" > /dev/tty
fi

if [[ -z "$API_KEY" ]]; then
  echo "API Key cannot be empty."
  exit 1
fi

mkdir -p "$APP_DIR" "$LOG_DIR" "$HOME/Library/LaunchAgents" "$CODEX_DIR"

cat > "$ADAPTER" <<'PYADAPTER'
#!/usr/bin/env python3
import json
import socket
import time
import traceback
import urllib.error
import urllib.parse
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = "127.0.0.1"
PORT = 18666
UPSTREAM = "https://maas-coding-api.cn-huabei-1.xf-yun.com/v2/chat/completions"
UPSTREAM_MODEL = "astron-code-latest"


def extract_text(value):
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        parts = [extract_text(item) for item in value]
        return "\n".join(part for part in parts if part)
    if isinstance(value, dict):
        for key in ("text", "content", "output", "result"):
            if key in value:
                text = extract_text(value[key])
                if text:
                    return text
        return json.dumps(value, ensure_ascii=False)
    return str(value)


def normalize_role(role):
    if role in ("developer", "system"):
        return "system"
    if role in ("assistant", "tool"):
        return role
    return "user"


def responses_to_messages(body):
    messages = []
    instructions = body.get("instructions")
    if instructions:
        messages.append({"role": "system", "content": extract_text(instructions)})

    inp = body.get("input", "")
    if isinstance(inp, str):
        if inp.strip():
            messages.append({"role": "user", "content": inp})
        return messages or [{"role": "user", "content": ""}]

    if isinstance(inp, list):
        for item in inp:
            if not isinstance(item, dict):
                text = extract_text(item)
                if text:
                    messages.append({"role": "user", "content": text})
                continue

            typ = item.get("type")
            if typ == "function_call_output":
                messages.append({
                    "role": "tool",
                    "tool_call_id": item.get("call_id") or item.get("id") or "call_unknown",
                    "content": extract_text(item.get("output")),
                })
                continue

            if typ == "function_call":
                messages.append({
                    "role": "assistant",
                    "content": None,
                    "tool_calls": [{
                        "id": item.get("call_id") or item.get("id") or "call_unknown",
                        "type": "function",
                        "function": {
                            "name": item.get("name") or "unknown",
                            "arguments": item.get("arguments") or "{}",
                        },
                    }],
                })
                continue

            role = normalize_role(item.get("role") or ("assistant" if typ == "message" else "user"))
            text = extract_text(item.get("content"))
            if not text and typ:
                text = extract_text(item)
            if text:
                messages.append({"role": role, "content": text})

    return messages or [{"role": "user", "content": ""}]


def responses_tools_to_chat_tools(tools):
    chat_tools = []
    for tool in tools or []:
        if not isinstance(tool, dict):
            continue
        if tool.get("type") != "function":
            continue
        name = tool.get("name") or tool.get("function", {}).get("name")
        if not name:
            continue
        chat_tools.append({
            "type": "function",
            "function": {
                "name": name,
                "description": tool.get("description") or tool.get("function", {}).get("description") or "",
                "parameters": tool.get("parameters") or tool.get("function", {}).get("parameters") or {"type": "object", "properties": {}},
            },
        })
    return chat_tools


def sse(handler, event, data):
    payload = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
    try:
        handler.wfile.write(f"event: {event}\n".encode("utf-8"))
        handler.wfile.write(f"data: {payload}\n\n".encode("utf-8"))
        handler.wfile.flush()
        return True
    except (BrokenPipeError, ConnectionResetError, socket.timeout):
        return False


def response_shell(response_id, model, status, output=None, usage=None):
    body = {
        "id": response_id,
        "object": "response",
        "created_at": int(time.time()),
        "status": status,
        "model": model,
        "output": output or [],
        "parallel_tool_calls": True,
        "tool_choice": "auto",
    }
    if usage:
        body["usage"] = usage
    return body


def output_from_chat_message(message):
    output = []
    text = message.get("content") or ""
    if text:
        output.append({
            "id": "msg_" + uuid.uuid4().hex,
            "type": "message",
            "status": "completed",
            "role": "assistant",
            "content": [{"type": "output_text", "text": text, "annotations": []}],
        })
    for call in message.get("tool_calls") or []:
        fn = call.get("function") or {}
        output.append({
            "id": "fc_" + uuid.uuid4().hex,
            "type": "function_call",
            "status": "completed",
            "call_id": call.get("id") or "call_" + uuid.uuid4().hex,
            "name": fn.get("name") or "unknown",
            "arguments": fn.get("arguments") or "{}",
        })
    return output


def output_from_text(text):
    return output_from_chat_message({"content": text})


class Handler(BaseHTTPRequestHandler):
    server_version = "xfyun-codex-adapter/0.3"

    def log_message(self, fmt, *args):
        print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {self.address_string()} {fmt % args}", flush=True)

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path in ("/health", "/v1/health"):
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"ok":true}')
            return
        if path in ("/models", "/v1/models"):
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({
                "object": "list",
                "data": [{"id": UPSTREAM_MODEL, "object": "model", "created": int(time.time()), "owned_by": "xfyun"}],
            }).encode("utf-8"))
            return
        self.send_error(404)

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        if not (path.startswith("/v1/responses") or path.startswith("/responses")):
            self.send_error(404)
            return
        try:
            length = int(self.headers.get("content-length", "0"))
            raw = self.rfile.read(length)
            body = json.loads(raw.decode("utf-8") or "{}")
            auth = self.headers.get("authorization") or self.headers.get("Authorization")
            if not auth:
                self.send_error(401, "Missing Authorization header")
                return

            messages = responses_to_messages(body)
            max_tokens = body.get("max_output_tokens") or body.get("max_tokens") or 4096
            upstream_body = {
                "model": UPSTREAM_MODEL,
                "messages": messages,
                "stream": False,
                "max_tokens": max_tokens,
            }
            chat_tools = responses_tools_to_chat_tools(body.get("tools"))
            if chat_tools:
                upstream_body["tools"] = chat_tools
                if body.get("tool_choice") and body.get("tool_choice") != "auto":
                    upstream_body["tool_choice"] = body.get("tool_choice")
            if "temperature" in body:
                upstream_body["temperature"] = body["temperature"]

            if body.get("stream", True) is not False:
                self.handle_stream(auth, upstream_body)
            else:
                self.handle_non_stream(auth, upstream_body)
        except (BrokenPipeError, ConnectionResetError, socket.timeout):
            return
        except Exception as exc:
            traceback.print_exc()
            self.send_response(500)
            self.send_header("content-type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"error": str(exc)}, ensure_ascii=False).encode("utf-8"))

    def upstream_request(self, auth, upstream_body):
        req = urllib.request.Request(
            UPSTREAM,
            data=json.dumps(upstream_body, ensure_ascii=False).encode("utf-8"),
            method="POST",
            headers={
                "Authorization": auth,
                "Content-Type": "application/json",
                "Accept": "application/json",
            },
        )
        return urllib.request.urlopen(req, timeout=600)

    def fetch_upstream(self, auth, upstream_body):
        with self.upstream_request(auth, upstream_body) as resp:
            return json.loads(resp.read().decode("utf-8"))

    def handle_non_stream(self, auth, upstream_body):
        try:
            data = self.fetch_upstream(auth, upstream_body)
        except urllib.error.HTTPError as err:
            payload = err.read()
            self.send_response(err.code)
            self.send_header("content-type", "application/json")
            self.end_headers()
            self.wfile.write(payload)
            return

        message = (data.get("choices") or [{}])[0].get("message") or {}
        output = output_from_chat_message(message)
        result = response_shell("resp_" + uuid.uuid4().hex, UPSTREAM_MODEL, "completed", output=output)
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(result, ensure_ascii=False).encode("utf-8"))

    def handle_stream(self, auth, upstream_body):
        response_id = "resp_" + uuid.uuid4().hex
        self.send_response(200)
        self.send_header("content-type", "text/event-stream; charset=utf-8")
        self.send_header("cache-control", "no-cache")
        self.send_header("connection", "close")
        self.end_headers()

        if not sse(self, "response.created", {
            "type": "response.created",
            "response": response_shell(response_id, UPSTREAM_MODEL, "in_progress"),
        }):
            return

        try:
            data = self.fetch_upstream(auth, upstream_body)
        except urllib.error.HTTPError as err:
            detail = err.read().decode("utf-8", "replace")
            print(f"upstream HTTP {err.code}: {detail}", flush=True)
            data = {"choices": [{"message": {"content": f"讯飞上游接口返回错误 HTTP {err.code}: {detail[:1200]}"}}]}
        except urllib.error.URLError as err:
            detail = str(err)
            print(f"upstream URL error: {detail}", flush=True)
            data = {"choices": [{"message": {"content": f"讯飞上游接口连接失败: {detail[:1200]}"}}]}

        message = (data.get("choices") or [{}])[0].get("message") or {}
        output = output_from_chat_message(message)
        usage = data.get("usage")
        mapped_usage = None
        if usage:
            mapped_usage = {
                "input_tokens": usage.get("prompt_tokens", 0),
                "output_tokens": usage.get("completion_tokens", 0),
                "total_tokens": usage.get("total_tokens", 0),
            }

        for index, item in enumerate(output):
            if not sse(self, "response.output_item.added", {
                "type": "response.output_item.added",
                "response_id": response_id,
                "output_index": index,
                "item": item,
            }):
                return
            if item.get("type") == "message":
                part = item["content"][0]
                if not sse(self, "response.content_part.added", {
                    "type": "response.content_part.added",
                    "response_id": response_id,
                    "item_id": item["id"],
                    "output_index": index,
                    "content_index": 0,
                    "part": {"type": "output_text", "text": "", "annotations": []},
                }):
                    return
                if not sse(self, "response.output_text.delta", {
                    "type": "response.output_text.delta",
                    "response_id": response_id,
                    "item_id": item["id"],
                    "output_index": index,
                    "content_index": 0,
                    "delta": part.get("text", ""),
                }):
                    return
                if not sse(self, "response.output_text.done", {
                    "type": "response.output_text.done",
                    "response_id": response_id,
                    "item_id": item["id"],
                    "output_index": index,
                    "content_index": 0,
                    "text": part.get("text", ""),
                }):
                    return
                if not sse(self, "response.content_part.done", {
                    "type": "response.content_part.done",
                    "response_id": response_id,
                    "item_id": item["id"],
                    "output_index": index,
                    "content_index": 0,
                    "part": part,
                }):
                    return
            if not sse(self, "response.output_item.done", {
                "type": "response.output_item.done",
                "response_id": response_id,
                "output_index": index,
                "item": item,
            }):
                return

        sse(self, "response.completed", {
            "type": "response.completed",
            "response": response_shell(response_id, UPSTREAM_MODEL, "completed", output=output, usage=mapped_usage),
        })
        self.close_connection = True


def main():
    httpd = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"xfyun codex adapter listening on http://{HOST}:{PORT}", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
PYADAPTER

chmod +x "$ADAPTER"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/python3</string>
    <string>${ADAPTER}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${LOG_DIR}/xfyun-codex-adapter.log</string>
  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/xfyun-codex-adapter.err.log</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart -k "gui/$(id -u)/${LABEL}"

for _ in {1..20}; do
  if /usr/bin/curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done

if ! /usr/bin/curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
  echo "Adapter failed to start. Check: ${LOG_DIR}/xfyun-codex-adapter.err.log"
  exit 1
fi

if [[ ! -f "$DB" ]]; then
  echo "Adapter installed, but CC Switch database was not found."
  echo "Open CC Switch once, then rerun this installer to auto-create the Provider."
  exit 0
fi

osascript -e 'tell application "CC Switch" to quit' >/dev/null 2>&1 || true
sleep 1

XFYUN_CODING_PLAN_API_KEY="$API_KEY" python3 <<'PYCONFIG'
import json
import os
from pathlib import Path
import sqlite3
import time

api_key = os.environ["XFYUN_CODING_PLAN_API_KEY"]
db = os.path.expanduser("~/.cc-switch/cc-switch.db")
provider_id = "xfyun-astron-adapter"
app_type = "codex"
base_url = "http://127.0.0.1:18666/v1"
model = "astron-code-latest"
config = f'''model = "{model}"
model_provider = "xfyun_astron_adapter"

[model_providers.xfyun_astron_adapter]
name = "Xunfei Astron Adapter"
base_url = "{base_url}"
wire_api = "responses"
requires_openai_auth = true
request_max_retries = 2
stream_max_retries = 2
stream_idle_timeout_ms = 300000
'''
settings = {"auth": {"OPENAI_API_KEY": api_key}, "config": config}
meta = {"commonConfigEnabled": True, "endpointAutoSelect": False}
now = int(time.time() * 1000)
home = Path.home()
cc_switch_dir = home / ".cc-switch"
settings_path = cc_switch_dir / "settings.json"
codex_dir = home / ".codex"
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


def provider_exists(con, provider):
    row = con.execute(
        "select 1 from providers where app_type=? and id=?",
        (app_type, provider),
    ).fetchone()
    return row is not None


def get_effective_current_provider(con):
    local_settings = read_json(settings_path, {})
    local_id = local_settings.get("currentProviderCodex") or local_settings.get("current_provider_codex")
    if local_id and provider_exists(con, local_id):
        return local_id
    row = con.execute(
        "select id from providers where app_type=? and is_current=1 limit 1",
        (app_type,),
    ).fetchone()
    return row[0] if row else None


def backfill_live_to_provider(con, provider):
    if not provider or provider == provider_id or not provider_exists(con, provider):
        return

    live_config = config_path.read_text(encoding="utf-8") if config_path.exists() else ""
    live_auth = read_json(auth_path, {}) if auth_path.exists() else {}
    if not live_config and not live_auth:
        return
    if "xfyun_astron_adapter" in live_config:
        return

    row = con.execute(
        "select settings_config from providers where app_type=? and id=?",
        (app_type, provider),
    ).fetchone()
    if not row:
        return
    try:
        current_settings = json.loads(row[0] or "{}")
    except json.JSONDecodeError:
        current_settings = {}
    if not isinstance(current_settings, dict):
        current_settings = {}
    current_settings["config"] = live_config
    current_settings["auth"] = live_auth
    con.execute(
        "update providers set settings_config=? where app_type=? and id=?",
        (json.dumps(current_settings, ensure_ascii=False, separators=(",", ":")), app_type, provider),
    )


def apply_current_provider(con, provider):
    con.execute("update providers set is_current=0 where app_type=?", (app_type,))
    con.execute(
        "update providers set is_current=1 where app_type=? and id=?",
        (app_type, provider),
    )

    local_settings = read_json(settings_path, {})
    if not isinstance(local_settings, dict):
        local_settings = {}
    local_settings["currentProviderCodex"] = provider
    local_settings.pop("current_provider_codex", None)
    write_json(settings_path, local_settings)


def write_live_codex_config():
    codex_dir.mkdir(parents=True, exist_ok=True)
    common_row = con.execute(
        "select value from settings where key='common_config_codex'",
    ).fetchone()
    common_config = (common_row[0] if common_row and common_row[0] else "").strip()
    final_config = config.strip()
    if common_config:
        final_config = final_config + "\n\n" + common_config
    config_path.write_text(final_config + "\n", encoding="utf-8")
    write_json(auth_path, {"OPENAI_API_KEY": api_key})

con = sqlite3.connect(db)
previous_provider = get_effective_current_provider(con)
backfill_live_to_provider(con, previous_provider)

max_sort = con.execute(
    "select coalesce(max(sort_index), -1) from providers where app_type=?",
    (app_type,),
).fetchone()[0]
con.execute(
    """
    insert into providers (
        id, app_type, name, settings_config, website_url, category, created_at, sort_index,
        notes, icon, icon_color, meta, is_current, in_failover_queue, cost_multiplier,
        limit_daily_usd, limit_monthly_usd, provider_type
    ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0, '1.0', NULL, NULL, NULL)
    on conflict(id, app_type) do update set
        name=excluded.name,
        settings_config=excluded.settings_config,
        website_url=excluded.website_url,
        category=excluded.category,
        notes=excluded.notes,
        icon=excluded.icon,
        icon_color=excluded.icon_color,
        meta=excluded.meta,
        cost_multiplier=excluded.cost_multiplier
    """,
    (
        provider_id,
        app_type,
        "Xunfei Astron Adapter",
        json.dumps(settings, ensure_ascii=False, separators=(",", ":")),
        "https://www.xfyun.cn/doc/spark/CodingPlan.html",
        "third_party",
        now,
        max_sort + 1,
        "Local adapter for Xfyun Coding Plan. Codex Responses API on localhost -> Xfyun Chat Completions upstream.",
        "custom-icon",
        "#0F766E",
        json.dumps(meta, ensure_ascii=False, separators=(",", ":")),
    ),
)
con.execute(
    "delete from provider_endpoints where provider_id=? and app_type=?",
    (provider_id, app_type),
)
con.execute(
    "insert into provider_endpoints(provider_id, app_type, url, added_at) values (?, ?, ?, ?)",
    (provider_id, app_type, base_url, now),
)
apply_current_provider(con, provider_id)
write_live_codex_config()
con.commit()
con.close()
PYCONFIG
open -a "CC Switch" >/dev/null 2>&1 || true

echo
echo "Installed successfully."
echo "Codex has been switched to 'Xunfei Astron Adapter'."
echo "Next: restart Codex."
echo "Adapter health: http://127.0.0.1:${PORT}/health"
