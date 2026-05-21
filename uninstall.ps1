$ErrorActionPreference = "Stop"

$ProviderId = "xfyun-astron-adapter"
$TaskName = "XfyunCodexAdapter"

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
  throw "This uninstaller currently supports Windows only."
}

$HomeDir = [System.Environment]::GetFolderPath("UserProfile")
$AppDir = Join-Path $HomeDir ".cc-switch"
$DefaultDb = Join-Path $AppDir "cc-switch.db"
if (-not (Test-Path $DefaultDb) -and -not [string]::IsNullOrWhiteSpace($env:HOME)) {
  $LegacyDir = Join-Path $env:HOME ".cc-switch"
  $LegacyDb = Join-Path $LegacyDir "cc-switch.db"
  if (Test-Path $LegacyDb) {
    $AppDir = $LegacyDir
  }
}

$Db = Join-Path $AppDir "cc-switch.db"
$SettingsPath = Join-Path $AppDir "settings.json"
$Adapter = Join-Path $AppDir "xfyun_codex_adapter.py"
$Runner = Join-Path $AppDir "xfyun_codex_adapter.cmd"
$CodexDir = Join-Path $HomeDir ".codex"
$CodexConfig = Join-Path $CodexDir "config.toml"
$CodexAuth = Join-Path $CodexDir "auth.json"

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

  return $null
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

try {
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
} catch {}
Stop-AdapterProcess

Stop-CcSwitch

$Python = Get-PythonInvocation
if ((Test-Path $Db) -and $Python) {
  $env:CC_SWITCH_DB = $Db
  $env:CC_SWITCH_SETTINGS = $SettingsPath
  $env:CODEX_CONFIG = $CodexConfig
  $env:CODEX_AUTH = $CodexAuth

  $script = @'
import json
import os
from pathlib import Path
import sqlite3

provider_id = "xfyun-astron-adapter"
app_type = "codex"
db = os.environ["CC_SWITCH_DB"]
settings_path = Path(os.environ["CC_SWITCH_SETTINGS"])
config_path = Path(os.environ["CODEX_CONFIG"])
auth_path = Path(os.environ["CODEX_AUTH"])


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
            config_path.parent.mkdir(parents=True, exist_ok=True)
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
'@

  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  $tempScript = Join-Path $env:TEMP "xfyun_codex_adapter_uninstall.py"
  [System.IO.File]::WriteAllText($tempScript, $script, $utf8NoBom)
  try {
    & $Python.Exe @($Python.Args + @($tempScript))
  } finally {
    Remove-Item -Force $tempScript -ErrorAction SilentlyContinue
  }
}

Remove-Item -Force $Adapter, $Runner -ErrorAction SilentlyContinue

Start-CcSwitch

Write-Host "Uninstalled Xunfei Astron Adapter."
