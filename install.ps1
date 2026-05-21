$ErrorActionPreference = "Stop"

$ProviderId = "xfyun-astron-adapter"
$ProviderName = "Xunfei Astron Adapter"
$Port = 18666
$BaseUrl = "http://127.0.0.1:$Port/v1"
$TaskName = "XfyunCodexAdapter"

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
  throw "This installer currently supports Windows only."
}

$HomeDir = [System.Environment]::GetFolderPath("UserProfile")
if ([string]::IsNullOrWhiteSpace($HomeDir)) {
  throw "Cannot locate the Windows user profile directory."
}

$AppDir = Join-Path $HomeDir ".cc-switch"
$DefaultDb = Join-Path $AppDir "cc-switch.db"
if (-not (Test-Path $DefaultDb) -and -not [string]::IsNullOrWhiteSpace($env:HOME)) {
  $LegacyDir = Join-Path $env:HOME ".cc-switch"
  $LegacyDb = Join-Path $LegacyDir "cc-switch.db"
  if (Test-Path $LegacyDb) {
    $AppDir = $LegacyDir
  }
}

$LogDir = Join-Path $AppDir "logs"
$Adapter = Join-Path $AppDir "xfyun_codex_adapter.py"
$Runner = Join-Path $AppDir "xfyun_codex_adapter.cmd"
$Db = Join-Path $AppDir "cc-switch.db"
$SettingsPath = Join-Path $AppDir "settings.json"
$CodexDir = Join-Path $HomeDir ".codex"
$CodexConfig = Join-Path $CodexDir "config.toml"
$CodexAuth = Join-Path $CodexDir "auth.json"

function ConvertFrom-SecureStringPlainText {
  param([Parameter(Mandatory = $true)][System.Security.SecureString]$SecureString)
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
  try {
    [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
  } finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
  }
}

function Get-PythonInvocation {
  $python = Get-Command python.exe -ErrorAction SilentlyContinue
  if ($python) {
    try {
      & $python.Source --version *> $null
      return @{ Exe = $python.Source; Args = @() }
    } catch {}
  }

  $py = Get-Command py.exe -ErrorAction SilentlyContinue
  if ($py) {
    try {
      & $py.Source -3 --version *> $null
      return @{ Exe = $py.Source; Args = @("-3") }
    } catch {}
  }

  throw "Python 3 is required. Please install Python 3 first, then rerun this installer."
}

function Invoke-DownloadText {
  param([Parameter(Mandatory = $true)][string[]]$Urls)
  foreach ($url in $Urls) {
    try {
      return (Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 30).Content
    } catch {
      Write-Host "Download failed: $url"
    }
  }
  throw "Failed to download adapter source from Gitee/GitHub."
}

function Stop-CcSwitch {
  $script:LastCcSwitchExe = $null
  $processes = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ProcessName -eq "cc-switch" -or $_.ProcessName -eq "CC Switch"
  })
  foreach ($process in $processes) {
    if (-not $script:LastCcSwitchExe -and $process.Path) {
      $script:LastCcSwitchExe = $process.Path
    }
    try {
      Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    } catch {}
  }
  if ($processes.Count -gt 0) {
    Start-Sleep -Seconds 1
  }
}

function Start-CcSwitch {
  $candidates = @()
  if ($script:LastCcSwitchExe) { $candidates += $script:LastCcSwitchExe }
  $programFilesX86 = [System.Environment]::GetEnvironmentVariable("ProgramFiles(x86)")
  $candidates += @(
    (Join-Path $env:LOCALAPPDATA "Programs\CC Switch\CC Switch.exe"),
    (Join-Path $env:ProgramFiles "CC Switch\CC Switch.exe")
  )
  if ($programFilesX86) {
    $candidates += (Join-Path $programFilesX86 "CC Switch\CC Switch.exe")
  }

  foreach ($candidate in $candidates) {
    if ($candidate -and (Test-Path $candidate)) {
      Start-Process -FilePath $candidate | Out-Null
      return
    }
  }
  Write-Host "CC Switch was updated. Please reopen CC Switch manually if it is not running."
}

function Stop-AdapterProcess {
  $processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $_.CommandLine -and $_.CommandLine -like "*xfyun_codex_adapter.py*"
  })
  foreach ($process in $processes) {
    try {
      Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    } catch {}
  }
}

$ApiKey = $env:XFYUN_CODING_PLAN_API_KEY
if ([string]::IsNullOrWhiteSpace($ApiKey)) {
  $secure = Read-Host "Paste your Xfyun Coding Plan API Key" -AsSecureString
  $ApiKey = ConvertFrom-SecureStringPlainText $secure
}
if ([string]::IsNullOrWhiteSpace($ApiKey)) {
  throw "API Key cannot be empty."
}

$Python = Get-PythonInvocation
New-Item -ItemType Directory -Force -Path $AppDir, $LogDir, $CodexDir | Out-Null

$installSh = Invoke-DownloadText @(
  "https://gitee.com/kangarooking/xfyun-codex-adapter/raw/main/install.sh",
  "https://raw.githubusercontent.com/kangarooking/xfyun-codex-adapter/main/install.sh"
)
$match = [regex]::Match($installSh, '(?s)cat > "\$ADAPTER" <<''PYADAPTER''\r?\n(.*?)\r?\nPYADAPTER')
if (-not $match.Success) {
  throw "Could not extract adapter source from install.sh."
}
$adapterSource = $match.Groups[1].Value
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($Adapter, $adapterSource, $utf8NoBom)

$pythonArgsForCmd = ""
if ($Python.Args.Count -gt 0) {
  $pythonArgsForCmd = ($Python.Args -join " ") + " "
}
$runnerContent = @"
@echo off
cd /d "$AppDir"
"$($Python.Exe)" $pythonArgsForCmd"$Adapter" >> "$LogDir\xfyun-codex-adapter.log" 2>> "$LogDir\xfyun-codex-adapter.err.log"
"@
[System.IO.File]::WriteAllText($Runner, $runnerContent, $utf8NoBom)

Stop-AdapterProcess
try {
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
} catch {}

$action = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c `"$Runner`""
$trigger = New-ScheduledTaskTrigger -AtLogOn
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Description "Local adapter for Xfyun Coding Plan and Codex" -Force | Out-Null
Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$Runner`"" -WindowStyle Hidden | Out-Null

$healthy = $false
for ($i = 0; $i -lt 30; $i++) {
  try {
    Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 2 | Out-Null
    $healthy = $true
    break
  } catch {
    Start-Sleep -Milliseconds 300
  }
}
if (-not $healthy) {
  throw "Adapter failed to start. Check logs: $LogDir"
}

if (-not (Test-Path $Db)) {
  Write-Host "Adapter installed, but CC Switch database was not found."
  Write-Host "Open CC Switch once, then rerun this installer to auto-create the Provider."
  exit 0
}

Stop-CcSwitch

$env:XFYUN_CODING_PLAN_API_KEY = $ApiKey
$env:CC_SWITCH_DB = $Db
$env:CC_SWITCH_SETTINGS = $SettingsPath
$env:CODEX_CONFIG = $CodexConfig
$env:CODEX_AUTH = $CodexAuth

$configScript = @'
import json
import os
from pathlib import Path
import sqlite3
import time

api_key = os.environ["XFYUN_CODING_PLAN_API_KEY"]
db = os.environ["CC_SWITCH_DB"]
settings_path = Path(os.environ["CC_SWITCH_SETTINGS"])
config_path = Path(os.environ["CODEX_CONFIG"])
auth_path = Path(os.environ["CODEX_AUTH"])
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


def write_live_codex_config(con):
    config_path.parent.mkdir(parents=True, exist_ok=True)
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
write_live_codex_config(con)
con.commit()
con.close()
'@

$tempConfigScript = Join-Path $env:TEMP "xfyun_codex_adapter_config.py"
[System.IO.File]::WriteAllText($tempConfigScript, $configScript, $utf8NoBom)
try {
  & $Python.Exe @($Python.Args + @($tempConfigScript))
} finally {
  Remove-Item -Force $tempConfigScript -ErrorAction SilentlyContinue
}

Start-CcSwitch

Write-Host ""
Write-Host "Installed successfully."
Write-Host "Codex has been switched to 'Xunfei Astron Adapter'."
Write-Host "Next: restart Codex."
Write-Host "Adapter health: http://127.0.0.1:$Port/health"
