param(
  [ValidateSet('Menu','Setup','Repair','Status','Restore','Update','Watchdog','Reconfigure')]
  [string]$Action = 'Menu'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Version = '0.2.0'
$Repo = 'Stas5252/antigravity-routeguard'
$Root = Join-Path $env:LOCALAPPDATA 'AGRouteGuard'
$ProxyCfg = Join-Path $Root 'proxy.json'
$Bridge = Join-Path $Root 'agbridge.exe'
$Injector = Join-Path $Root 'version.dll'
$StartBridge = Join-Path $Root 'Start-Bridge.ps1'
$InstalledScript = Join-Path $Root 'AGRouteGuard.ps1'
$InstallDirFile = Join-Path $Root 'install-dir.txt'
$BridgeTaskName = 'AG RouteGuard Bridge'
$WatchdogTaskName = 'AG RouteGuard Watchdog'
$RouteGuardMarker = 'AG RouteGuard - generated, local bridge only'

function Say($m,$c='Gray'){ Write-Host $m -ForegroundColor $c }
function Ensure-Root { New-Item -ItemType Directory -Path $Root -Force | Out-Null }

function Find-Antigravity {
  $candidates = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Antigravity\Antigravity.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Antigravity IDE\Antigravity IDE.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Antigravity\Antigravity IDE.exe')
  )
  foreach($p in $candidates){ if(Test-Path $p){ return $p } }

  $base = Join-Path $env:LOCALAPPDATA 'Programs'
  if(Test-Path $base){
    $hit = Get-ChildItem $base -Filter 'Antigravity*.exe' -Recurse -ErrorAction SilentlyContinue |
      Where-Object { $_.FullName -notmatch '\\uninstall|\\update' } |
      Select-Object -First 1
    if($hit){ return $hit.FullName }
  }
  throw 'Antigravity.exe not found. Install Antigravity first.'
}

function Get-ProxyPlain {
  if(!(Test-Path $ProxyCfg)){ throw 'Proxy is not configured. Run Setup/Reconfigure.' }
  $cfg = Get-Content $ProxyCfg -Raw | ConvertFrom-Json
  $secure = $cfg.password_dpapi | ConvertTo-SecureString
  $cred = New-Object System.Management.Automation.PSCredential('x',$secure)
  [pscustomobject]@{
    host=[string]$cfg.host
    port=[int]$cfg.port
    username=[string]$cfg.username
    password=$cred.GetNetworkCredential().Password
    local_addr=if($cfg.local_addr){[string]$cfg.local_addr}else{'127.0.0.1:17890'}
  }
}

function Save-Proxy {
  Ensure-Root
  Say 'Proxy host/IP:' 'Cyan'; $hostv = (Read-Host).Trim()
  if([string]::IsNullOrWhiteSpace($hostv)){ throw 'Proxy host cannot be empty.' }
  Say 'Proxy port:' 'Cyan'; $portv = [int](Read-Host)
  if($portv -lt 1 -or $portv -gt 65535){ throw 'Proxy port must be 1-65535.' }
  Say 'Proxy username (leave empty for no-auth):' 'Cyan'; $userv = Read-Host
  Say 'Proxy password (leave empty for no-auth):' 'Cyan'; $sec = Read-Host -AsSecureString
  $enc = $sec | ConvertFrom-SecureString
  [pscustomobject]@{
    host=$hostv
    port=$portv
    username=$userv
    password_dpapi=$enc
    local_addr='127.0.0.1:17890'
  } | ConvertTo-Json | Set-Content $ProxyCfg -Encoding UTF8
  Say 'Proxy credentials saved with Windows DPAPI for this Windows user.' 'Green'
}

function Install-Files {
  Ensure-Root
  $required = @('agbridge.exe','version.dll','Start-Bridge.ps1','AGRouteGuard.ps1')
  foreach($f in $required){
    $src = if($f -eq 'Start-Bridge.ps1'){ Join-Path $PSScriptRoot 'Start-Bridge.ps1' } else { Join-Path $PSScriptRoot $f }
    if(!(Test-Path $src)){ throw "$f is missing from the release package." }
  }
  Copy-Item (Join-Path $PSScriptRoot 'agbridge.exe') $Bridge -Force
  Copy-Item (Join-Path $PSScriptRoot 'version.dll') $Injector -Force
  Copy-Item (Join-Path $PSScriptRoot 'Start-Bridge.ps1') $StartBridge -Force
  if((Resolve-Path $PSCommandPath).Path -ne $InstalledScript){ Copy-Item $PSCommandPath $InstalledScript -Force }
}

function Set-BridgeEnvironment {
  $p = Get-ProxyPlain
  $env:AG_UPSTREAM_HOST=[string]$p.host
  $env:AG_UPSTREAM_PORT=[string]$p.port
  $env:AG_UPSTREAM_USER=[string]$p.username
  $env:AG_UPSTREAM_PASS=[string]$p.password
  $env:AG_LOCAL_ADDR=[string]$p.local_addr
}

function Start-BridgeNow {
  if(!(Test-Path $ProxyCfg)){ throw 'Proxy is not configured. Run Setup.' }
  if(!(Test-Path $Bridge)){ throw 'agbridge.exe is missing. Run Setup/Repair from a release package.' }
  if(Get-Process agbridge -ErrorAction SilentlyContinue){ return }
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $StartBridge
  Start-Sleep -Milliseconds 800
  if(-not (Get-Process agbridge -ErrorAction SilentlyContinue)){ throw 'Bridge did not start.' }
}

function Check-Egress([switch]$Quiet) {
  Set-BridgeEnvironment
  $ip = & $Bridge --check 2>&1
  if($LASTEXITCODE -ne 0){ throw "Proxy check failed: $ip" }
  $ip = ($ip | Out-String).Trim()
  if(-not $Quiet){ Say "Proxy egress IP: $ip" 'Green' }
  return $ip
}

function Write-InjectorConfig($installDir) {
  $cfg = @{
    _comment=$RouteGuardMarker
    _version=$Version
    log_level='info'
    proxy=@{host='127.0.0.1';port=17890;type='socks5'}
    fake_ip=@{enabled=$true;cidr='198.18.0.0/15'}
    timeout=@{connect=12000;send=30000;recv=180000}
    updates=@{enabled=$false;check_delay_ms=15000;timeout_ms=5000;notify_once=$true;allow_insecure_mirrors=$false;mirrors=@()}
    traffic_logging=$false
    diagnostics=@{agent_ip_probe=$true}
    child_injection=$true
    child_injection_mode='filtered'
    child_injection_exclude=@()
    target_processes=@(
      'agy.exe','language_server.exe','language_server_windows','language_server_windows_x64.exe',
      'Antigravity.exe','Antigravity IDE.exe','node.exe'
    )
    proxy_rules=@{
      allowed_ports=@(80,443)
      dns_mode='proxy'
      ipv6_mode='block'
      udp_mode='block'
      udp_fallback='block'
      routing=@{enabled=$true;priority_mode='order';default_action='proxy';use_default_private=$true;rules=@()}
    }
  }
  $cfg | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $installDir 'config.json') -Encoding UTF8
}

function Backup-IfNeeded($dir,$name) {
  $dst = Join-Path $dir $name
  if(Test-Path $dst){
    $safeLeaf = (Split-Path $dir -Leaf) -replace '[^A-Za-z0-9._-]','_'
    $bak = Join-Path $Root ("backup-$safeLeaf-$name")
    if(!(Test-Path $bak)){ Copy-Item $dst $bak -Force }
  }
}

function Apply-Patch([switch]$Quiet) {
  if(!(Test-Path $Injector)){ throw 'version.dll payload missing. Run Setup/Repair from the release package.' }
  $exe = Find-Antigravity
  $dir = Split-Path $exe -Parent
  Backup-IfNeeded $dir 'version.dll'
  Backup-IfNeeded $dir 'config.json'

  Copy-Item $Injector (Join-Path $dir 'version.dll') -Force
  Write-InjectorConfig $dir
  Set-Content $InstallDirFile $dir -Encoding UTF8
  if(-not $Quiet){ Say "Patched: $dir" 'Green' }
}

function Test-PatchCurrent {
  try {
    $exe = Find-Antigravity
    $dir = Split-Path $exe -Parent
    $dstDll = Join-Path $dir 'version.dll'
    $cfgPath = Join-Path $dir 'config.json'
    if(!(Test-Path $dstDll) -or !(Test-Path $Injector) -or !(Test-Path $cfgPath)){ return $false }
    if((Get-FileHash $dstDll -Algorithm SHA256).Hash -ne (Get-FileHash $Injector -Algorithm SHA256).Hash){ return $false }
    try {
      $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
      return [string]$cfg._comment -eq $RouteGuardMarker
    } catch { return $false }
  } catch { return $false }
}

function Register-Tasks {
  if(!(Test-Path $InstalledScript)){ throw 'Installed AGRouteGuard.ps1 is missing.' }
  $bridgeCmd = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$StartBridge`""
  schtasks.exe /Create /TN $BridgeTaskName /SC ONLOGON /TR $bridgeCmd /F | Out-Null

  $watchdogCmd = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$InstalledScript`" -Action Watchdog"
  schtasks.exe /Create /TN $WatchdogTaskName /SC MINUTE /MO 5 /TR $watchdogCmd /F | Out-Null
}

function Remove-Tasks {
  schtasks.exe /Delete /TN $BridgeTaskName /F 2>$null | Out-Null
  schtasks.exe /Delete /TN $WatchdogTaskName /F 2>$null | Out-Null
}

function Get-LatestLsLog {
  $roots = @(
    (Join-Path $env:APPDATA 'Antigravity\logs'),
    (Join-Path $env:APPDATA 'Antigravity IDE\logs')
  )
  foreach($root in $roots){
    if(Test-Path $root){
      $hit = Get-ChildItem $root -Filter 'ls-main.log' -Recurse -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
      if($hit){ return $hit.FullName }
    }
  }
  return $null
}

function Get-Location400Status {
  $log = Get-LatestLsLog
  if(!$log){ return $null }
  try {
    $tail = Get-Content $log -Tail 400 -ErrorAction Stop | Out-String
    [pscustomobject]@{ path=$log; hit=($tail -match 'User location is not supported for the API use') }
  } catch { return $null }
}

function Do-Setup {
  Install-Files
  Save-Proxy
  Check-Egress | Out-Null
  Start-BridgeNow
  Apply-Patch
  Register-Tasks
  Say 'Setup complete. Close Antigravity completely, then open it again.' 'Green'
  Say 'Happ/TUN is not required for this setup; keeping a second VPN layer can add instability.' 'Yellow'
}

function Do-Reconfigure {
  Install-Files
  Save-Proxy
  Check-Egress | Out-Null
  Stop-Process -Name agbridge -Force -ErrorAction SilentlyContinue
  Start-BridgeNow
  Apply-Patch
  Register-Tasks
  Say 'Proxy changed and RouteGuard repaired.' 'Green'
}

function Do-Repair([switch]$Quiet) {
  if(Test-Path (Join-Path $PSScriptRoot 'agbridge.exe')){ Install-Files }
  Start-BridgeNow
  Check-Egress -Quiet | Out-Null
  Apply-Patch -Quiet:$Quiet
  Register-Tasks
  if(-not $Quiet){ Say 'Repair complete. Restart Antigravity if it was already open.' 'Green' }
}

function Do-Watchdog {
  try {
    Ensure-Root
    if(!(Test-Path $ProxyCfg) -or !(Test-Path $Bridge) -or !(Test-Path $Injector)){ return }
    Start-BridgeNow
    if(-not (Test-PatchCurrent)){ Apply-Patch -Quiet }
  } catch {
    $log = Join-Path $Root 'watchdog.log'
    "$(Get-Date -Format o) $($_.Exception.Message)" | Add-Content $log -Encoding UTF8
  }
}

function Do-Status {
  Say "AG RouteGuard v$Version" 'Magenta'
  Say "Bridge process: $([bool](Get-Process agbridge -ErrorAction SilentlyContinue))" 'Cyan'
  Say "Patch current: $(Test-PatchCurrent)" 'Cyan'
  if(Test-Path $ProxyCfg){
    try { Check-Egress | Out-Null } catch { Say $_.Exception.Message 'Red' }
  } else { Say 'Proxy not configured.' 'Yellow' }

  try {
    $exe=Find-Antigravity
    $dir=Split-Path $exe -Parent
    Say "Antigravity: $exe" 'Cyan'
    Say "version.dll installed: $([bool](Test-Path (Join-Path $dir 'version.dll')))" 'Cyan'
  } catch { Say $_.Exception.Message 'Red' }

  $loc = Get-Location400Status
  if($loc){
    if($loc.hit){ Say "Latest agent log still contains Google location 400: $($loc.path)" 'Red' }
    else { Say "No location 400 found in the tail of latest agent log: $($loc.path)" 'Green' }
  }
}

function Do-Restore {
  Stop-Process -Name agbridge -Force -ErrorAction SilentlyContinue
  Remove-Tasks
  if(Test-Path $InstallDirFile){
    $dir=(Get-Content $InstallDirFile -Raw).Trim()
    $safeLeaf = (Split-Path $dir -Leaf) -replace '[^A-Za-z0-9._-]','_'
    foreach($name in @('version.dll','config.json')){
      $dst=Join-Path $dir $name
      $bak=Join-Path $Root ("backup-$safeLeaf-$name")
      if(Test-Path $bak){ Copy-Item $bak $dst -Force }
      elseif(Test-Path $dst){ Remove-Item $dst -Force }
    }
  }
  Say 'Restored backups and removed RouteGuard scheduled tasks.' 'Green'
}

function Parse-Checksum($text,$fileName) {
  foreach($line in ($text -split "`r?`n")){
    if($line -match '^([0-9a-fA-F]{64})\s+\*?(.+)$'){
      if($matches[2].Trim() -eq $fileName){ return $matches[1].ToLowerInvariant() }
    }
  }
  return $null
}

function Do-Update {
  $api="https://api.github.com/repos/$Repo/releases/latest"
  try { $rel=Invoke-RestMethod $api -Headers @{ 'User-Agent'="AGRouteGuard/$Version" } }
  catch { throw "Update check failed: $($_.Exception.Message)" }

  Say "Installed: v$Version  Latest: $($rel.tag_name)" 'Cyan'
  $zipAsset = $rel.assets | Where-Object { $_.name -eq 'AGRouteGuard-win-x64.zip' } | Select-Object -First 1
  $sumAsset = $rel.assets | Where-Object { $_.name -eq 'SHA256SUMS.txt' } | Select-Object -First 1
  if(!$zipAsset -or !$sumAsset){ throw 'Latest release is missing package/checksum assets.' }

  $temp = Join-Path $env:TEMP ("AGRouteGuard-update-" + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $temp -Force | Out-Null
  try {
    $zip = Join-Path $temp 'AGRouteGuard-win-x64.zip'
    $sum = Join-Path $temp 'SHA256SUMS.txt'
    Invoke-WebRequest $zipAsset.browser_download_url -OutFile $zip -Headers @{ 'User-Agent'="AGRouteGuard/$Version" }
    Invoke-WebRequest $sumAsset.browser_download_url -OutFile $sum -Headers @{ 'User-Agent'="AGRouteGuard/$Version" }
    $expected = Parse-Checksum (Get-Content $sum -Raw) 'AGRouteGuard-win-x64.zip'
    if(!$expected){ throw 'Could not parse SHA256SUMS.txt.' }
    $actual = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    if($actual -ne $expected){ throw "SHA-256 mismatch. expected=$expected actual=$actual" }

    $unpack = Join-Path $temp 'unpack'
    Expand-Archive $zip $unpack -Force
    foreach($f in @('AGRouteGuard.ps1','agbridge.exe','version.dll','Start-Bridge.ps1')){
      $src = Join-Path $unpack $f
      if(!(Test-Path $src)){ throw "Release package missing $f" }
      Copy-Item $src (Join-Path $Root $f) -Force
    }
    Stop-Process -Name agbridge -Force -ErrorAction SilentlyContinue
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $InstalledScript -Action Repair
    Say 'RouteGuard updated and repaired.' 'Green'
  } finally {
    Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Menu {
  Write-Host ''
  Say "AG RouteGuard v$Version" 'Magenta'
  Write-Host '1) Setup   2) Repair   3) Status   4) Reconfigure proxy   5) Update   6) Restore   0) Exit'
  switch(Read-Host 'Choose'){
    '1'{Do-Setup}
    '2'{Do-Repair}
    '3'{Do-Status}
    '4'{Do-Reconfigure}
    '5'{Do-Update}
    '6'{Do-Restore}
    default{ }
  }
}

switch($Action){
  'Setup'{Do-Setup}
  'Repair'{Do-Repair}
  'Status'{Do-Status}
  'Restore'{Do-Restore}
  'Update'{Do-Update}
  'Watchdog'{Do-Watchdog}
  'Reconfigure'{Do-Reconfigure}
  default{Menu}
}
