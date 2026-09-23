$ErrorActionPreference = 'Stop'
$Root = Join-Path $env:LOCALAPPDATA 'AGRouteGuard'
$CfgPath = Join-Path $Root 'proxy.json'
$Bridge = Join-Path $Root 'agbridge.exe'
if (!(Test-Path $CfgPath) -or !(Test-Path $Bridge)) { exit 2 }

$cfg = Get-Content $CfgPath -Raw | ConvertFrom-Json
$secure = $cfg.password_dpapi | ConvertTo-SecureString
$cred = New-Object System.Management.Automation.PSCredential('x', $secure)
$plain = $cred.GetNetworkCredential().Password

$env:AG_UPSTREAM_HOST = [string]$cfg.host
$env:AG_UPSTREAM_PORT = [string]$cfg.port
$env:AG_UPSTREAM_USER = [string]$cfg.username
$env:AG_UPSTREAM_PASS = $plain
$env:AG_LOCAL_ADDR = if ($cfg.local_addr) { [string]$cfg.local_addr } else { '127.0.0.1:17890' }

$existing = Get-CimInstance Win32_Process -Filter "Name='agbridge.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.ExecutablePath -eq $Bridge }
if ($existing) { exit 0 }

Start-Process -FilePath $Bridge -WindowStyle Hidden -WorkingDirectory $Root
