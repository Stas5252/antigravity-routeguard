param(
  [ValidateSet('Menu','Setup','Repair','Status','Report','Restore','Update','AutoUpdate','Watchdog','Reconfigure')]
  [string]$Action = 'Menu'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Version = '0.4.0'
$Repo = 'Stas5252/antigravity-routeguard'
$Root = Join-Path $env:LOCALAPPDATA 'AGRouteGuard'
$BackupDir = Join-Path $Root 'backups'
$ManagedDir = Join-Path $Root 'managed'
$ProxyCfg = Join-Path $Root 'proxy.json'
$Bridge = Join-Path $Root 'agbridge.exe'
$Injector = Join-Path $Root 'version.dll'
$StartBridge = Join-Path $Root 'Start-Bridge.ps1'
$InstalledScript = Join-Path $Root 'AGRouteGuard.ps1'
$InstallDirFile = Join-Path $Root 'install-dir.txt'
$InstalledReleaseHash = Join-Path $Root 'installed-release.sha256'
$LastUpdateCheck = Join-Path $Root 'last-update-check.txt'
$PendingUpdate = Join-Path $Root 'pending-update.txt'
$PendingRepair = Join-Path $Root 'pending-repair.txt'
$BridgeTaskName = 'AG RouteGuard Bridge'
$WatchdogTaskName = 'AG RouteGuard Watchdog'
$RouteGuardMarker = 'AG RouteGuard - generated, local bridge only'
$NrptComment = 'AG RouteGuard gate DNS'
$GateDns = '127.0.0.53'
$GateMap = @{
  'cloudcode-pa.googleapis.com' = '127.65.71.1'
  'daily-cloudcode-pa.googleapis.com' = '127.65.71.2'
}

function Say($m,$c='Gray'){ Write-Host $m -ForegroundColor $c }
function Ensure-Root {
  New-Item -ItemType Directory -Path $Root -Force | Out-Null
  New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
  New-Item -ItemType Directory -Path $ManagedDir -Force | Out-Null
}

function Test-IsAdmin {
  try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch { return $false }
}

function Ensure-AdminInteractive {
  if(Test-IsAdmin){ return }
  if($Action -notin @('Setup','Reconfigure','Restore')){ return }
  Say 'RouteGuard needs Administrator once to install/remove the two NRPT gate-DNS rules.' 'Yellow'
  $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Action {1}' -f $PSCommandPath,$Action
  Start-Process powershell.exe -Verb RunAs -ArgumentList $argLine | Out-Null
  exit
}

function Find-Antigravity {
  $candidates=New-Object System.Collections.Generic.List[string]
  $pf86=[Environment]::GetEnvironmentVariable('ProgramFiles(x86)')

  foreach($root in @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Antigravity'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Antigravity IDE'),
    $(if($env:ProgramFiles){Join-Path $env:ProgramFiles 'Antigravity'}),
    $(if($env:ProgramFiles){Join-Path $env:ProgramFiles 'Antigravity IDE'}),
    $(if($pf86){Join-Path $pf86 'Antigravity'}),
    $(if($pf86){Join-Path $pf86 'Antigravity IDE'})
  )){
    if(!$root){ continue }
    foreach($exe in @('Antigravity.exe','Antigravity IDE.exe')){
      [void]$candidates.Add((Join-Path $root $exe))
    }
  }

  foreach($hive in @(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
  )){
    try {
      foreach($app in @(Get-ItemProperty $hive -ErrorAction SilentlyContinue | Where-Object {
        [string]$_.DisplayName -match 'Antigravity'
      })){
        $loc=[string]$app.InstallLocation
        if(!$loc){ continue }
        foreach($exe in @('Antigravity.exe','Antigravity IDE.exe')){
          [void]$candidates.Add((Join-Path $loc $exe))
        }
      }
    } catch {}
  }

  foreach($p in @($candidates | Select-Object -Unique)){
    if(Test-Path -LiteralPath $p){ return $p }
  }

  foreach($base in @(
    (Join-Path $env:LOCALAPPDATA 'Programs'),
    $env:ProgramFiles,
    $pf86
  )){
    if(!$base -or !(Test-Path -LiteralPath $base)){ continue }
    $hit=Get-ChildItem -LiteralPath $base -Filter 'Antigravity*.exe' -Recurse -Depth 4 -File -ErrorAction SilentlyContinue |
      Where-Object { $_.FullName -notmatch '\\uninstall|\\update|\\temp' } |
      Sort-Object LastWriteTime -Descending |
      Select-Object -First 1
    if($hit){ return $hit.FullName }
  }

  throw 'Antigravity.exe not found. Install Antigravity first or place it in a standard Windows application directory.'
}

function Get-InstallDir {
  return (Split-Path (Find-Antigravity) -Parent)
}

function Get-AntigravityProcesses {
  return @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ProcessName -like 'Antigravity*' -or $_.ProcessName -like 'language_server*' -or $_.ProcessName -eq 'agy'
  })
}

function Assert-AntigravityClosed {
  $p=@(Get-AntigravityProcesses)
  if($p.Count -gt 0){
    $names=($p | Select-Object -ExpandProperty ProcessName -Unique) -join ', '
    throw "Close Antigravity completely before patching. Running: $names"
  }
}

function Show-LiveLanguageServerEgress {
  try {
    $pids=@(Get-Process -Name 'language_server*' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
    if($pids.Count -eq 0){
      Say 'Live language-server egress: not running.' 'Yellow'
      return
    }
    $conns=@(Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
      Where-Object { $pids -contains $_.OwningProcess -and $_.RemotePort -in @(443,17890) })
    if($conns.Count -eq 0){
      Say 'Live language-server egress: no established 443/proxy sockets yet.' 'Yellow'
      return
    }
    $direct=@($conns | Where-Object {
      $_.RemotePort -eq 443 -and $_.RemoteAddress -notlike '127.*' -and $_.RemoteAddress -ne '::1'
    })
    $local=@($conns | Where-Object {
      $_.RemoteAddress -like '127.*' -or $_.RemoteAddress -eq '::1' -or $_.RemotePort -eq 17890
    })
    if($direct.Count -gt 0){
      Say "LIVE EGRESS WARNING: language_server has $($direct.Count) direct non-loopback TLS socket(s)." 'Red'
    } elseif($local.Count -gt 0){
      Say "Live language-server egress: loopback/proxy only ($($local.Count) socket(s) observed)." 'Green'
    } else {
      Say 'Live language-server egress: established sockets are inconclusive.' 'Yellow'
    }
  } catch {
    Say "Live egress probe unavailable: $($_.Exception.Message)" 'Yellow'
  }
}

function Assert-NoKnownPatcherConflict {
  $ours='http://127.0.0.1:17890'
  $ag=[Environment]::GetEnvironmentVariable('AG_LS_PROXY','User')
  if($ag -and $ag -ne $ours){
    throw "Another Antigravity proxy channel is active (AG_LS_PROXY=$ag). Disable/restore the previous patcher first."
  }

  $oldPorts=@('53129','43129','44129','45129','46129','47129','48129')
  foreach($name in @('HTTPS_PROXY','HTTP_PROXY')){
    foreach($scope in @('User','Machine')){
      $v=[Environment]::GetEnvironmentVariable($name,$scope)
      if(!$v){ continue }
      try {
        $uri=[uri]$v
        if($uri.Host -in @('127.0.0.1','localhost') -and ([string]$uri.Port) -in $oldPorts){
          throw "Stale unlocker proxy detected: $name ($scope) -> $v. Disable/restore the old unlocker before RouteGuard setup."
        }
      } catch [System.Management.Automation.RuntimeException] {
        throw
      } catch {}
    }
  }

  if(Get-Process -Name 'ag_dns' -ErrorAction SilentlyContinue){
    throw 'Another Antigravity unlocker relay (ag_dns.exe) is running. Turn it off before RouteGuard setup.'
  }

  try {
    $dir=Get-InstallDir
    foreach($path in @(
      (Join-Path $dir 'resources\app\out\main.js'),
      (Join-Path $dir 'resources\app\main.js')
    )){
      if(!(Test-Path $path)){ continue }
      $text=Get-Content $path -Raw -Encoding UTF8
      if($text -match '\[AG_PROXY_HOOK\]|/\*\[AG_PATCHED\]\*/'){
        throw "Legacy Antigravity JS/proxy patch detected in $path. Restore that patch or reinstall Antigravity cleanly before RouteGuard setup."
      }
    }
  } catch {
    if($_.Exception.Message -match 'Legacy Antigravity|Another Antigravity'){ throw }
  }
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

function Copy-IfDifferentPath($source,$destination) {
  $src = [IO.Path]::GetFullPath($source)
  $dst = [IO.Path]::GetFullPath($destination)
  if($src -ne $dst){ Copy-Item $src $dst -Force }
}

function Install-Files {
  Ensure-Root
  $required = @('agbridge.exe','version.dll','Start-Bridge.ps1','AGRouteGuard.ps1')
  foreach($f in $required){
    $src = if($f -eq 'Start-Bridge.ps1'){ Join-Path $PSScriptRoot 'Start-Bridge.ps1' } else { Join-Path $PSScriptRoot $f }
    if(!(Test-Path $src)){ throw "$f is missing from the release package." }
  }
  Copy-IfDifferentPath (Join-Path $PSScriptRoot 'agbridge.exe') $Bridge
  Copy-IfDifferentPath (Join-Path $PSScriptRoot 'version.dll') $Injector
  Copy-IfDifferentPath (Join-Path $PSScriptRoot 'Start-Bridge.ps1') $StartBridge
  Copy-IfDifferentPath $PSCommandPath $InstalledScript
}

function Set-BridgeEnvironment {
  $p = Get-ProxyPlain
  $env:AG_UPSTREAM_HOST=[string]$p.host
  $env:AG_UPSTREAM_PORT=[string]$p.port
  $env:AG_UPSTREAM_USER=[string]$p.username
  $env:AG_UPSTREAM_PASS=[string]$p.password
  $env:AG_LOCAL_ADDR=[string]$p.local_addr
}

function Get-BridgeProcess {
  try {
    return @(Get-CimInstance Win32_Process -Filter "Name='agbridge.exe'" -ErrorAction SilentlyContinue |
      Where-Object { $_.ExecutablePath -eq $Bridge })
  } catch {
    return @(Get-Process agbridge -ErrorAction SilentlyContinue)
  }
}

function Stop-BridgeNow {
  foreach($p in @(Get-BridgeProcess)){
    try {
      $pid=if($null -ne $p.ProcessId){[int]$p.ProcessId}else{[int]$p.Id}
      Stop-Process -Id $pid -Force -ErrorAction Stop
    } catch {}
  }
}

function Start-BridgeNow {
  if(!(Test-Path $ProxyCfg)){ throw 'Proxy is not configured. Run Setup.' }
  if(!(Test-Path $Bridge)){ throw 'agbridge.exe is missing. Run Setup/Repair from a release package.' }
  if(@(Get-BridgeProcess).Count -gt 0){ return }
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $StartBridge
  Start-Sleep -Milliseconds 900
  if(@(Get-BridgeProcess).Count -eq 0){ throw 'RouteGuard bridge did not start. Check bridge.err.log.' }
}

function Check-Egress([switch]$Quiet) {
  Set-BridgeEnvironment
  $ips=@()
  for($i=0; $i -lt 3; $i++){
    $raw = & $Bridge --check 2>&1
    if($LASTEXITCODE -ne 0){ throw "Proxy check $($i+1)/3 failed: $raw" }
    $ip = ($raw | Out-String).Trim()
    if([string]::IsNullOrWhiteSpace($ip)){ throw "Proxy check $($i+1)/3 returned an empty IP." }
    $ips += $ip
    Start-Sleep -Milliseconds 300
  }
  $unique=@($ips | Select-Object -Unique)
  if($unique.Count -ne 1){ throw "Proxy egress changed during 3 checks: $($unique -join ', '). Use a sticky/static proxy." }
  if(-not $Quiet){ Say "Proxy egress IP (3/3 stable): $($unique[0])" 'Green' }
  return $unique[0]
}

function Check-GooglePath([switch]$Quiet) {
  Set-BridgeEnvironment
  $out = & $Bridge --probe-google 2>&1
  if($LASTEXITCODE -ne 0){
    throw "Google/CloudCode TLS probe through the proxy failed: $($out | Out-String)"
  }
  if(-not $Quiet){
    foreach($line in @($out)){ if($line){ Say "Google path: $line" 'Green' } }
  }
  return $true
}

function Save-ProxyValidated {
  $oldExists = Test-Path $ProxyCfg
  $old = if($oldExists){ Get-Content $ProxyCfg -Raw } else { $null }
  try {
    Save-Proxy
    Check-Egress | Out-Null
    Check-GooglePath | Out-Null
  } catch {
    if($oldExists){ Set-Content $ProxyCfg $old -Encoding UTF8 }
    else { Remove-Item $ProxyCfg -Force -ErrorAction SilentlyContinue }
    throw
  }
}

function Get-OurNrptRules {
  if(-not (Get-Command Get-DnsClientNrptRule -ErrorAction SilentlyContinue)){ return @() }
  return @(Get-DnsClientNrptRule -ErrorAction SilentlyContinue | Where-Object { $_.Comment -eq $NrptComment })
}

function Ensure-GateNrpt([switch]$Quiet) {
  if(-not (Test-IsAdmin)){
    if(-not $Quiet){ Say 'NRPT not checked: Administrator is required.' 'Yellow' }
    return $false
  }
  if(-not (Get-Command Add-DnsClientNrptRule -ErrorAction SilentlyContinue)){
    if(-not $Quiet){ Say 'NRPT cmdlets are unavailable on this Windows build.' 'Yellow' }
    return $false
  }

  $all=@(Get-DnsClientNrptRule -ErrorAction SilentlyContinue)
  foreach($host in $GateMap.Keys){
    $foreign=@($all | Where-Object {
      ($_.Namespace -contains $host -or [string]$_.Namespace -eq $host) -and $_.Comment -ne $NrptComment
    })
    if($foreign.Count -gt 0){
      throw "A foreign NRPT rule already exists for $host. RouteGuard refuses to overwrite another VPN/DNS policy."
    }
    $ours=@($all | Where-Object {
      ($_.Namespace -contains $host -or [string]$_.Namespace -eq $host) -and $_.Comment -eq $NrptComment
    })
    if($ours.Count -eq 0){
      Add-DnsClientNrptRule -Namespace $host -NameServers $GateDns -Comment $NrptComment | Out-Null
      if(-not $Quiet){ Say "NRPT: $host -> DNS $GateDns" 'Green' }
    }
  }
  Clear-DnsClientCache -ErrorAction SilentlyContinue
  return $true
}

function Remove-GateNrpt {
  if(-not (Test-IsAdmin)){ return }
  foreach($r in @(Get-OurNrptRules)){
    try { Remove-DnsClientNrptRule -Name $r.Name -Force -ErrorAction Stop | Out-Null } catch {}
  }
  Clear-DnsClientCache -ErrorAction SilentlyContinue
}

function Get-BridgePids {
  $ids=@()
  foreach($p in @(Get-BridgeProcess)){
    if($null -ne $p.ProcessId){ $ids += [int]$p.ProcessId }
    elseif($null -ne $p.Id){ $ids += [int]$p.Id }
  }
  return @($ids | Select-Object -Unique)
}

function Test-GateListeners([switch]$Quiet) {
  $pids=@(Get-BridgePids)
  if($pids.Count -eq 0){
    if(-not $Quiet){ Say 'Gate listeners: RouteGuard bridge is not running.' 'Red' }
    return $false
  }

  $ok=$true
  try {
    $listeners=@(Get-NetTCPConnection -State Listen -LocalPort 443 -ErrorAction Stop)
    foreach($host in $GateMap.Keys){
      $ip=[string]$GateMap[$host]
      $owned=@($listeners | Where-Object {
        $_.LocalAddress -eq $ip -and $pids -contains [int]$_.OwningProcess
      })
      if($owned.Count -eq 0){
        $ok=$false
        if(-not $Quiet){ Say "Gate listener missing/not owned by RouteGuard: ${ip}:443 ($host)" 'Red' }
      } elseif(-not $Quiet){
        Say "Gate listener owned by RouteGuard: ${ip}:443 ($host)" 'Green'
      }
    }
  } catch {
    if(-not $Quiet){ Say "Gate listener ownership check failed: $($_.Exception.Message)" 'Yellow' }
    return $false
  }
  return $ok
}

function Test-GateDns {
  $ok=$true
  foreach($host in $GateMap.Keys){
    $expected=$GateMap[$host]
    try {
      $ans=Resolve-DnsName $host -Type A -Server $GateDns -DnsOnly -QuickTimeout -ErrorAction Stop |
        Where-Object { $_.IPAddress } | Select-Object -First 1
      $got=[string]$ans.IPAddress
      if($got -ne $expected){ $ok=$false; Say "Gate DNS ${host}: expected $expected, got $got" 'Red' }
      else { Say "Gate DNS $host -> $got" 'Green' }
    } catch {
      $ok=$false
      Say "Gate DNS $host failed: $($_.Exception.Message)" 'Red'
    }
  }
  return $ok
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

function Get-PathKey($path) {
  $full=[IO.Path]::GetFullPath($path).ToLowerInvariant()
  $sha=[Security.Cryptography.SHA256]::Create()
  try {
    $bytes=[Text.Encoding]::UTF8.GetBytes($full)
    return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()
  } finally { $sha.Dispose() }
}

function Install-ManagedFile($source,$target,$kind) {
  Ensure-Root
  if(!(Test-Path -LiteralPath $source)){ throw "Managed source missing: $source" }

  $key=Get-PathKey $target
  $metaPath=Join-Path $ManagedDir "$key.json"
  $bakPath=Join-Path $ManagedDir "$key.original"
  $meta=$null
  if(Test-Path $metaPath){
    try { $meta=Get-Content $metaPath -Raw | ConvertFrom-Json } catch { $meta=$null }
  }

  $currentExists=Test-Path -LiteralPath $target
  $currentHash=if($currentExists){(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash}else{''}
  $refreshOriginal=$true

  if($meta -and $meta.installed_hash -and $currentExists -and $currentHash -eq [string]$meta.installed_hash){
    # Still our previous payload: preserve the original backup across repairs.
    $refreshOriginal=$false
  }

  if($refreshOriginal){
    if($currentExists){
      Copy-Item -LiteralPath $target -Destination $bakPath -Force
      $originalExists=$true
      $originalHash=$currentHash
    } else {
      Remove-Item -LiteralPath $bakPath -Force -ErrorAction SilentlyContinue
      $originalExists=$false
      $originalHash=''
    }
  } else {
    $originalExists=[bool]$meta.original_exists
    $originalHash=[string]$meta.original_hash
  }

  $targetDir=Split-Path $target -Parent
  New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
  $tmp=Join-Path $targetDir ('.routeguard-' + [IO.Path]::GetFileName($target) + "-$PID.tmp")
  try {
    Copy-Item -LiteralPath $source -Destination $tmp -Force
    Move-Item -LiteralPath $tmp -Destination $target -Force
  } finally {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
  }

  $installedHash=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
  [pscustomobject]@{
    target=[IO.Path]::GetFullPath($target)
    kind=$kind
    original_exists=$originalExists
    original_hash=$originalHash
    original_backup=$bakPath
    installed_hash=$installedHash
    updated_utc=[DateTime]::UtcNow.ToString('o')
  } | ConvertTo-Json | Set-Content $metaPath -Encoding UTF8
}

function Restore-ManagedFiles {
  Ensure-Root
  $processed=0
  foreach($metaFile in @(Get-ChildItem $ManagedDir -Filter '*.json' -File -ErrorAction SilentlyContinue)){
    $processed++
    try {
      $m=Get-Content $metaFile.FullName -Raw | ConvertFrom-Json
      $target=[string]$m.target
      $currentExists=Test-Path -LiteralPath $target
      $currentHash=if($currentExists){(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash}else{''}

      if($currentExists -and $m.installed_hash -and $currentHash -eq [string]$m.installed_hash){
        if([bool]$m.original_exists -and (Test-Path -LiteralPath ([string]$m.original_backup))){
          Copy-Item -LiteralPath ([string]$m.original_backup) -Destination $target -Force
          Say "Restored original managed file: $target" 'Green'
        } elseif(-not [bool]$m.original_exists) {
          Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
          Say "Removed RouteGuard-created file: $target" 'Green'
        }
      } elseif($currentExists) {
        Say "Managed target changed since RouteGuard installed it; leaving newer/foreign file untouched: $target" 'Yellow'
      }

      Remove-Item -LiteralPath ([string]$m.original_backup) -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $metaFile.FullName -Force -ErrorAction SilentlyContinue
    } catch {
      Say "Managed-file restore warning: $($_.Exception.Message)" 'Yellow'
    }
  }
  return $processed
}

function Save-PatchBackup($path,$kind) {
  Ensure-Root
  $key=Get-PathKey $path
  $bak=Join-Path $BackupDir "$key.bak"
  $meta=Join-Path $BackupDir "$key.json"
  Copy-Item $path $bak -Force
  [pscustomobject]@{
    target=[IO.Path]::GetFullPath($path)
    kind=$kind
    original_hash=(Get-FileHash $path -Algorithm SHA256).Hash
    patched_hash=''
    backup=$bak
  } | ConvertTo-Json | Set-Content $meta -Encoding UTF8
  return $meta
}

function Finish-PatchBackup($metaPath,$target) {
  if(!(Test-Path $metaPath)){ return }
  $m=Get-Content $metaPath -Raw | ConvertFrom-Json
  $m.patched_hash=(Get-FileHash $target -Algorithm SHA256).Hash
  $m | ConvertTo-Json | Set-Content $metaPath -Encoding UTF8
}

function Write-BytesAtomic($path,[byte[]]$bytes) {
  $tmp="$path.routeguard.$PID.tmp"
  try {
    [IO.File]::WriteAllBytes($tmp,$bytes)
    Move-Item $tmp $path -Force
  } finally {
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
  }
}

function Patch-IneligibleField($path,[switch]$Quiet) {
  if(!(Test-Path $path)){ return $false }
  $bytes=[IO.File]::ReadAllBytes($path)
  $ascii=[Text.Encoding]::ASCII.GetString($bytes)
  $latin=[Text.Encoding]::GetEncoding(28591).GetString($bytes)
  $name=[IO.Path]::GetFileName($path).ToLowerInvariant()
  $rxOpt=[Text.RegularExpressions.RegexOptions]::Singleline

  $needEligibility=$ascii.Contains('ineligible')
  $needProxyVar=$ascii.Contains('https_proxy')
  $hasEligibility=$ascii.Contains('inexigible')
  $hasProxyVar=$ascii.Contains('AG_LS_PROXY')

  # Open AG Patcher uses these exact x64 gates for two additional local checks.
  # We only touch them when the known signature matches; unknown builds are left
  # alone instead of guessing offsets.
  # Three currently observed Windows x64 CLI layouts. The longer context
  # avoids patching a coincidental short instruction sequence.
  $cliPatterns=@(
    "\x48\x85\xc0\x0f\x84....\x80\x78\x08\x00\x0f\x85....\xe8....\x48\x89\x84\x24\x80\x00\x00\x00\x48\x89\x5c\x24\x50\x48\x89\x4c\x24\x70",
    "\x48\x85\xc0\x0f\x84....\x80\x78\x08\x00\x0f\x85....\xe8....\x48\x89\x84\x24\x88\x00\x00\x00\x48\x89\x5c\x24\x50\x48\x89\x4c\x24\x78",
    "\x48\x85\xc0\x0f\x84....\x80\x78\x08\x00\x0f\x85....\xe8....\x48\x89\x84\x24\x88\x00\x00\x00\x48\x89\x5c\x24\x50\x48\x89\x4c\x24\x70"
  )
  $cliPatchedPatterns=@(
    "\x48\x85\xc0\x0f\x84....\x48\x85\xc0\x90\x0f\x85....\xe8....\x48\x89\x84\x24\x80\x00\x00\x00\x48\x89\x5c\x24\x50\x48\x89\x4c\x24\x70",
    "\x48\x85\xc0\x0f\x84....\x48\x85\xc0\x90\x0f\x85....\xe8....\x48\x89\x84\x24\x88\x00\x00\x00\x48\x89\x5c\x24\x50\x48\x89\x4c\x24\x78",
    "\x48\x85\xc0\x0f\x84....\x48\x85\xc0\x90\x0f\x85....\xe8....\x48\x89\x84\x24\x88\x00\x00\x00\x48\x89\x5c\x24\x50\x48\x89\x4c\x24\x70"
  )
  $managerPattern="\x80\x78\x08\x00\x74.\x48\x8b.\x24.\x48\x89.\x60"
  $managerPatched="\xc6\x40\x08\x01\x90\x90\x48\x8b.\x24.\x48\x89.\x60"

  $cliMatches=@()
  $managerMatches=@()
  $hasCliGate=$false
  $hasManagerGate=$false

  if($name -eq 'agy.exe'){
    foreach($pattern in $cliPatterns){
      $cliMatches += @([regex]::Matches($latin,$pattern,$rxOpt))
    }
    foreach($pattern in $cliPatchedPatterns){
      if([regex]::IsMatch($latin,$pattern,$rxOpt)){ $hasCliGate=$true }
    }
  }
  if($name.StartsWith('language_server')){
    $managerMatches=@([regex]::Matches($latin,$managerPattern,$rxOpt))
    $hasManagerGate=[regex]::IsMatch($latin,$managerPatched,$rxOpt)
  }

  $needCliGate=$cliMatches.Count -eq 1
  $cliAmbiguous=$cliMatches.Count -gt 1
  $needManagerGate=$managerMatches.Count -eq 1
  $managerAmbiguous=$managerMatches.Count -gt 1

  $anyChange=$needEligibility -or $needProxyVar -or $needCliGate -or $needManagerGate
  if(-not $anyChange){
    if($hasEligibility -or $hasProxyVar -or $hasCliGate -or $hasManagerGate){
      if(-not $Quiet){ Say "Client binary gates already patched: $path" 'DarkGreen' }
      return $true
    }
    if($cliAmbiguous -and -not $Quiet){ Say "CLI eligibility signature is not unique; refusing to guess: $path" 'Yellow' }
    if($managerAmbiguous -and -not $Quiet){ Say "Manager auth signature is not unique; refusing to guess: $path" 'Yellow' }
    return $false
  }

  $meta=Save-PatchBackup $path 'client-binary-gates'
  $changes=@()

  if($needEligibility){
    $to=[Text.Encoding]::ASCII.GetBytes('inexigible')
    $pos=0
    $count=0
    while($true){
      $idx=$ascii.IndexOf('ineligible',$pos,[StringComparison]::Ordinal)
      if($idx -lt 0){ break }
      [Array]::Copy($to,0,$bytes,$idx,$to.Length)
      $count++
      $pos=$idx+10
    }
    $changes += "ineligible->inexigible x$count"
  }

  if($needProxyVar){
    $to=[Text.Encoding]::ASCII.GetBytes('AG_LS_PROXY')
    $pos=0
    $count=0
    while($true){
      $idx=$ascii.IndexOf('https_proxy',$pos,[StringComparison]::Ordinal)
      if($idx -lt 0){ break }
      [Array]::Copy($to,0,$bytes,$idx,$to.Length)
      $count++
      $pos=$idx+11
    }
    $changes += "https_proxy->AG_LS_PROXY x$count"
  }

  if($needCliGate){
    $fix=[byte[]](0x48,0x85,0xc0,0x90)
    [Array]::Copy($fix,0,$bytes,$cliMatches[0].Index+9,$fix.Length)
    $changes += 'agy eligibility gate x1'
  } elseif($cliAmbiguous -and -not $Quiet) {
    Say "CLI eligibility signature is not unique; skipped machine-code gate: $path" 'Yellow'
  }

  if($needManagerGate){
    $fix=[byte[]](0xc6,0x40,0x08,0x01,0x90,0x90)
    [Array]::Copy($fix,0,$bytes,$managerMatches[0].Index,$fix.Length)
    $changes += 'language_server hasValidAuth=true'
  } elseif($managerAmbiguous -and -not $Quiet) {
    Say "Manager auth signature is not unique; skipped machine-code gate: $path" 'Yellow'
  }

  Write-BytesAtomic $path $bytes
  Finish-PatchBackup $meta $path
  if(-not $Quiet){ Say "Client binary patched ($($changes -join '; ')): $path" 'Green' }
  return $true
}

function Ensure-PrivateProxyEnv {
  $value='http://127.0.0.1:17890'
  [Environment]::SetEnvironmentVariable('AG_LS_PROXY',$value,'User')
  $env:AG_LS_PROXY=$value
}

function Remove-PrivateProxyEnv {
  $ours='http://127.0.0.1:17890'
  $cur=[Environment]::GetEnvironmentVariable('AG_LS_PROXY','User')
  if($cur -eq $ours){ [Environment]::SetEnvironmentVariable('AG_LS_PROXY',$null,'User') }
  if($env:AG_LS_PROXY -eq $ours){ Remove-Item Env:AG_LS_PROXY -ErrorAction SilentlyContinue }
}

function Patch-IdeMainJs($installDir,[switch]$Quiet) {
  $paths=@(
    (Join-Path $installDir 'resources\app\out\main.js'),
    (Join-Path $installDir 'resources\app\main.js')
  )
  $pattern='(resetIsTierGCPTos\(\),)this\.[A-Za-z_$0-9]+\.isGoogleInternal'
  $done='resetIsTierGCPTos(),true'
  $patched=$false

  foreach($path in $paths){
    if(!(Test-Path $path)){ continue }
    $text=Get-Content $path -Raw -Encoding UTF8
    if($text.Contains($done)){
      $patched=$true
      if(-not $Quiet){ Say "IDE account-region gate already patched: $path" 'DarkGreen' }
      continue
    }
    if(-not [regex]::IsMatch($text,$pattern)){ continue }

    $meta=Save-PatchBackup $path 'ide-main-js'
    $new=[regex]::Replace($text,$pattern,'${1}true')
    [IO.File]::WriteAllText($path,$new,(New-Object Text.UTF8Encoding($false)))
    Finish-PatchBackup $meta $path
    $patched=$true
    if(-not $Quiet){ Say "IDE isGoogleInternal gate patched: $path" 'Green' }
  }

  if($patched){
    foreach($cache in @(
      (Join-Path $env:APPDATA 'Antigravity IDE\CachedData'),
      (Join-Path $env:APPDATA 'Antigravity IDE\Code Cache\js'),
      (Join-Path $env:APPDATA 'Antigravity\CachedData'),
      (Join-Path $env:APPDATA 'Antigravity\Code Cache\js')
    )){
      Remove-Item $cache -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
  return $patched
}

function Get-EligibilityTargets($installDir) {
  $out=@()
  foreach($p in @(
    (Join-Path $installDir 'agy.exe'),
    (Join-Path $installDir 'resources\bin\language_server.exe'),
    (Join-Path $installDir 'resources\app\extensions\antigravity\bin\language_server_windows_x64.exe'),
    (Join-Path $installDir 'resources\app\extensions\antigravity\bin\language_server.exe')
  )){
    if(Test-Path $p){ $out += $p }
  }
  foreach($p in @(Get-ChildItem $installDir -Filter 'language_server*.exe' -Recurse -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)){
    if($out -notcontains $p){ $out += $p }
  }
  return $out
}

function Apply-EligibilityPatches($installDir,[switch]$Quiet) {
  $count=0
  foreach($p in @(Get-EligibilityTargets $installDir)){
    try { if(Patch-IneligibleField $p -Quiet:$Quiet){ $count++ } }
    catch {
      if(-not $Quiet){ Say "Eligibility patch deferred for $p : $($_.Exception.Message)" 'Yellow' }
    }
  }
  try { if(Patch-IdeMainJs $installDir -Quiet:$Quiet){ $count++ } }
  catch { if(-not $Quiet){ Say "IDE JS patch deferred: $($_.Exception.Message)" 'Yellow' } }
  return $count
}

function Test-EligibilityPatch($installDir) {
  $results=@()
  $rxOpt=[Text.RegularExpressions.RegexOptions]::Singleline
  $cliStock=@(
    "\x48\x85\xc0\x0f\x84....\x80\x78\x08\x00\x0f\x85....\xe8....\x48\x89\x84\x24\x80\x00\x00\x00\x48\x89\x5c\x24\x50\x48\x89\x4c\x24\x70",
    "\x48\x85\xc0\x0f\x84....\x80\x78\x08\x00\x0f\x85....\xe8....\x48\x89\x84\x24\x88\x00\x00\x00\x48\x89\x5c\x24\x50\x48\x89\x4c\x24\x78",
    "\x48\x85\xc0\x0f\x84....\x80\x78\x08\x00\x0f\x85....\xe8....\x48\x89\x84\x24\x88\x00\x00\x00\x48\x89\x5c\x24\x50\x48\x89\x4c\x24\x70"
  )
  $cliDone=@(
    "\x48\x85\xc0\x0f\x84....\x48\x85\xc0\x90\x0f\x85....\xe8....\x48\x89\x84\x24\x80\x00\x00\x00\x48\x89\x5c\x24\x50\x48\x89\x4c\x24\x70",
    "\x48\x85\xc0\x0f\x84....\x48\x85\xc0\x90\x0f\x85....\xe8....\x48\x89\x84\x24\x88\x00\x00\x00\x48\x89\x5c\x24\x50\x48\x89\x4c\x24\x78",
    "\x48\x85\xc0\x0f\x84....\x48\x85\xc0\x90\x0f\x85....\xe8....\x48\x89\x84\x24\x88\x00\x00\x00\x48\x89\x5c\x24\x50\x48\x89\x4c\x24\x70"
  )
  $managerStock="\x80\x78\x08\x00\x74.\x48\x8b.\x24.\x48\x89.\x60"
  $managerDone="\xc6\x40\x08\x01\x90\x90\x48\x8b.\x24.\x48\x89.\x60"

  foreach($p in @(Get-EligibilityTargets $installDir)){
    try {
      $bytes=[IO.File]::ReadAllBytes($p)
      $ascii=[Text.Encoding]::ASCII.GetString($bytes)
      $latin=[Text.Encoding]::GetEncoding(28591).GetString($bytes)
      $name=[IO.Path]::GetFileName($p).ToLowerInvariant()
      $machine='not-applicable'

      if($name -eq 'agy.exe'){
        $stock=0; $done=0
        foreach($pattern in $cliStock){ $stock += [regex]::Matches($latin,$pattern,$rxOpt).Count }
        foreach($pattern in $cliDone){ $done += [regex]::Matches($latin,$pattern,$rxOpt).Count }
        if($done -gt 0 -and $stock -eq 0){ $machine='patched' }
        elseif($stock -eq 1 -and $done -eq 0){ $machine='unpatched' }
        elseif($stock -gt 1 -or ($stock -gt 0 -and $done -gt 0)){ $machine='ambiguous' }
        else { $machine='unknown' }
      } elseif($name.StartsWith('language_server')){
        $stock=[regex]::Matches($latin,$managerStock,$rxOpt).Count
        $done=[regex]::Matches($latin,$managerDone,$rxOpt).Count
        if($done -eq 1 -and $stock -eq 0){ $machine='patched' }
        elseif($stock -eq 1 -and $done -eq 0){ $machine='unpatched' }
        elseif($stock -gt 1 -or $done -gt 1 -or ($stock -gt 0 -and $done -gt 0)){ $machine='ambiguous' }
        else { $machine='unknown' }
      }

      $results += [pscustomobject]@{
        path=$p
        patched=$ascii.Contains('inexigible')
        stock=$ascii.Contains('ineligible')
        privateProxy=$ascii.Contains('AG_LS_PROXY')
        stockProxy=$ascii.Contains('https_proxy')
        machineGate=$machine
      }
    } catch {}
  }
  return $results
}

function Apply-Patch([switch]$Quiet) {
  if(!(Test-Path $Injector)){ throw 'version.dll payload missing. Run Setup/Repair from the release package.' }
  $dir=Get-InstallDir

  $stage=Join-Path $Root ("stage-" + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $stage -Force | Out-Null
  try {
    Write-InjectorConfig $stage
    Install-ManagedFile $Injector (Join-Path $dir 'version.dll') 'injector-dll'
    Install-ManagedFile (Join-Path $stage 'config.json') (Join-Path $dir 'config.json') 'injector-config'
  } finally {
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
  }

  Apply-EligibilityPatches $dir -Quiet:$Quiet | Out-Null
  Ensure-PrivateProxyEnv
  Set-Content $InstallDirFile $dir -Encoding UTF8
  if(-not $Quiet){ Say "RouteGuard applied: $dir" 'Green' }
}

function Test-PatchCurrent {
  try {
    $dir=Get-InstallDir
    $dstDll=Join-Path $dir 'version.dll'
    $cfgPath=Join-Path $dir 'config.json'
    if(!(Test-Path $dstDll) -or !(Test-Path $Injector) -or !(Test-Path $cfgPath)){ return $false }
    if((Get-FileHash $dstDll -Algorithm SHA256).Hash -ne (Get-FileHash $Injector -Algorithm SHA256).Hash){ return $false }
    $cfg=Get-Content $cfgPath -Raw | ConvertFrom-Json
    if([string]$cfg._comment -ne $RouteGuardMarker){ return $false }

    $elig=@(Test-EligibilityPatch $dir)
    if(@($elig | Where-Object {
      ($_.stock -and -not $_.patched) -or
      ($_.stockProxy -and -not $_.privateProxy) -or
      ($_.machineGate -eq 'unpatched')
    }).Count -gt 0){ return $false }
    return $true
  } catch { return $false }
}

function Register-Tasks {
  if(!(Test-Path $InstalledScript)){ throw 'Installed AGRouteGuard.ps1 is missing.' }
  $bridgeCmd = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$StartBridge`""
  schtasks.exe /Create /TN $BridgeTaskName /SC ONLOGON /TR $bridgeCmd /F | Out-Null

  $watchdogCmd = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$InstalledScript`" -Action Watchdog"
  $args=@('/Create','/TN',$WatchdogTaskName,'/SC','MINUTE','/MO','5','/TR',$watchdogCmd,'/F')
  if(Test-IsAdmin){ $args += @('/RL','HIGHEST') }
  & schtasks.exe @args | Out-Null
}

function Remove-Tasks {
  schtasks.exe /Delete /TN $BridgeTaskName /F 2>$null | Out-Null
  schtasks.exe /Delete /TN $WatchdogTaskName /F 2>$null | Out-Null
}

function Get-LatestLsLog {
  $roots=@(
    (Join-Path $env:APPDATA 'Antigravity\logs'),
    (Join-Path $env:APPDATA 'Antigravity IDE\logs')
  )
  $candidates=@()
  foreach($root in $roots){
    if(Test-Path $root){
      $candidates += @(Get-ChildItem $root -Filter 'ls-main.log' -Recurse -File -ErrorAction SilentlyContinue)
      $candidates += @(Get-ChildItem $root -Filter 'language_server.log' -Recurse -File -ErrorAction SilentlyContinue)
    }
  }
  $hit=$candidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if($hit){ return $hit.FullName }
  return $null
}

function Get-Location400Status {
  $log=Get-LatestLsLog
  if(!$log){ return $null }
  try {
    $tail=Get-Content $log -Tail 600 -ErrorAction Stop | Out-String
    [pscustomobject]@{
      path=$log
      location400=($tail -match 'User location is not supported for the API use')
      accountIneligible=($tail -match 'not eligible|eligibility')
      account403=($tail -match 'PERMISSION_DENIED|HTTP 403|code 403')
      quota429=($tail -match 'RESOURCE_EXHAUSTED|HTTP 429|code 429')
      license3501=($tail -match '#3501|valid license of this product')
      proxyBypass=($tail -match 'proxyconnect|connectex|connection refused')
    }
  } catch { return $null }
}

function Do-Setup {
  Ensure-AdminInteractive
  Assert-AntigravityClosed
  Install-Files
  Assert-NoKnownPatcherConflict
  Save-ProxyValidated
  Stop-BridgeNow
  Start-BridgeNow
  if(-not (Test-GateListeners)){ throw 'CloudCode gate listeners are not owned by RouteGuard. Another local service may be using a required loopback port.' }
  Ensure-GateNrpt | Out-Null
  if(-not (Test-GateDns)){ throw 'Gate DNS self-test failed. Do not launch Antigravity until Status is green.' }
  Apply-Patch
  Remove-Item $PendingRepair,$PendingUpdate -Force -ErrorAction SilentlyContinue
  Register-Tasks
  Say 'Setup complete. Launch Antigravity and run Status after the first model request.' 'Green'
  Say 'Happ/TUN is not required for this setup. Test RouteGuard alone first.' 'Yellow'
}

function Do-Reconfigure {
  Ensure-AdminInteractive
  Assert-AntigravityClosed
  Install-Files
  Assert-NoKnownPatcherConflict
  Save-ProxyValidated
  Stop-BridgeNow
  Start-BridgeNow
  if(-not (Test-GateListeners)){ throw 'CloudCode gate listeners are not owned by RouteGuard after proxy change.' }
  Ensure-GateNrpt | Out-Null
  if(-not (Test-GateDns)){ throw 'Gate DNS self-test failed after proxy change.' }
  Apply-Patch
  Remove-Item $PendingRepair -Force -ErrorAction SilentlyContinue
  Register-Tasks
  Say 'Proxy changed, validated against Google/CloudCode, and RouteGuard repaired.' 'Green'
}

function Do-Repair([switch]$Quiet) {
  if(@(Get-AntigravityProcesses).Count -gt 0){
    Set-Content $PendingRepair (Get-Date -Format o) -Encoding ASCII
    if(-not $Quiet){ Say 'Repair deferred safely: close Antigravity; watchdog will repair it automatically.' 'Yellow' }
    return
  }
  if(Test-Path (Join-Path $PSScriptRoot 'agbridge.exe')){ Install-Files }
  Stop-BridgeNow
  Start-BridgeNow
  if(-not (Test-GateListeners -Quiet)){ throw 'CloudCode gate listeners are unavailable.' }
  Check-Egress -Quiet | Out-Null
  Check-GooglePath -Quiet | Out-Null
  if(Test-IsAdmin){ Ensure-GateNrpt -Quiet | Out-Null }
  Apply-Patch -Quiet:$Quiet
  Remove-Item $PendingRepair -Force -ErrorAction SilentlyContinue
  Register-Tasks
  if(-not $Quiet){ Say 'Repair complete.' 'Green' }
}

function Test-UpdateCheckDue {
  if(!(Test-Path $LastUpdateCheck)){ return $true }
  try {
    $last=[datetime]::Parse((Get-Content $LastUpdateCheck -Raw).Trim())
    return ((Get-Date) - $last).TotalHours -ge 12
  } catch { return $true }
}

function Do-Watchdog {
  try {
    Ensure-Root
    if(!(Test-Path $ProxyCfg) -or !(Test-Path $Bridge) -or !(Test-Path $Injector)){ return }
    Start-BridgeNow

    $running=@(Get-AntigravityProcesses).Count -gt 0
    if(-not (Test-PatchCurrent)){
      if($running){
        Set-Content $PendingRepair (Get-Date -Format o) -Encoding ASCII
      } else {
        Apply-Patch -Quiet
        Remove-Item $PendingRepair -Force -ErrorAction SilentlyContinue
      }
    } elseif((Test-Path $PendingRepair) -and -not $running) {
      Apply-Patch -Quiet
      Remove-Item $PendingRepair -Force -ErrorAction SilentlyContinue
    }

    if((Test-Path $PendingUpdate) -and -not $running){
      Do-Update -Automatic
    } elseif((Test-UpdateCheckDue) -and -not $running) {
      Do-Update -Automatic
    }
  } catch {
    $log = Join-Path $Root 'watchdog.log'
    "$(Get-Date -Format o) $($_.Exception.Message)" | Add-Content $log -Encoding UTF8
  }
}

function Get-LatestInjectorLog {
  $roots=@()
  try { $roots += (Join-Path (Get-InstallDir) 'logs') } catch {}
  $roots += (Join-Path $env:TEMP 'antigravity-proxy-logs')
  $files=@()
  foreach($root in $roots){
    if(Test-Path $root){
      $files += @(Get-ChildItem $root -Filter 'proxy*.log' -File -ErrorAction SilentlyContinue)
    }
  }
  $hit=$files | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if($hit){ return $hit.FullName }
  return $null
}

function Show-InjectorDiagnostics {
  $log=Get-LatestInjectorLog
  if(!$log){
    Say 'Injector diagnostics: no proxy log yet (launch Antigravity once).' 'Yellow'
    return
  }
  try {
    $tail=@(Get-Content $log -Tail 1200 -ErrorAction Stop)
    $ls=@($tail | Where-Object { $_ -match 'language_server' -and $_ -match '注入|inject' })
    $gate=@($tail | Where-Object {
      $_ -match 'cloudcode-pa\.googleapis\.com' -and $_ -match 'SOCKS5|tunnel|隧道|CONNECT'
    })
    $ip=@($tail | Where-Object { $_ -match '\[诊断/IP\]|agent.*ip|egress' })
    if($ls.Count -gt 0){ Say 'Injector saw language_server process.' 'Green' }
    else { Say 'Injector has not yet logged language_server injection.' 'Yellow' }
    if($gate.Count -gt 0){ Say 'Injector saw CloudCode traffic on the proxy path.' 'Green' }
    else { Say 'Injector has not yet logged CloudCode traffic.' 'Yellow' }
    if($ip.Count -gt 0){
      $last=[string]$ip[-1]
      if($last.Length -gt 350){ $last=$last.Substring(0,350)+'...' }
      Say "Injector egress diagnostic: $last" 'Cyan'
    }
    Say "Injector log: $log" 'DarkGray'
  } catch {
    Say "Injector diagnostics unavailable: $($_.Exception.Message)" 'Yellow'
  }
}

function Show-BridgeDiagnostics {
  $log=Join-Path $Root 'bridge.err.log'
  if(!(Test-Path $log)){ return }
  try {
    $tail=@(Get-Content $log -Tail 300 -ErrorAction Stop)
    $pin=@($tail | Where-Object { $_ -match 'pinned upstream egress:' })
    $blocked=@($tail | Where-Object { $_ -match 'EGRESS CHANGED:|EGRESS UNVERIFIED:' })
    $restored=@($tail | Where-Object { $_ -match 'egress restored:' })
    if($pin.Count -gt 0){ Say ([string]$pin[-1]) 'Cyan' }
    if($blocked.Count -gt 0){
      $lastBlocked=[string]$blocked[-1]
      $lastRestore=if($restored.Count -gt 0){[string]$restored[-1]}else{''}
      $blockedIndex=[Array]::LastIndexOf([object[]]$tail,$lastBlocked)
      $restoreIndex=if($lastRestore){[Array]::LastIndexOf([object[]]$tail,$lastRestore)}else{-1}
      if($restoreIndex -gt $blockedIndex){
        Say 'Bridge egress safety gate triggered earlier but the expected IP was restored.' 'Yellow'
      } else {
        Say "Bridge FAIL-CLOSED: $lastBlocked" 'Red'
      }
    }
  } catch {}
}

function Show-CompetingProxySettings {
  $ours='http://127.0.0.1:17890'
  $ag=[Environment]::GetEnvironmentVariable('AG_LS_PROXY','User')
  if($ag -eq $ours){ Say 'Private AG_LS_PROXY channel: RouteGuard' 'Green' }
  elseif($ag){ Say 'Private AG_LS_PROXY channel is set by something else.' 'Yellow' }
  else { Say 'Private AG_LS_PROXY channel is not set.' 'Yellow' }

  foreach($name in @('HTTPS_PROXY','HTTP_PROXY','ALL_PROXY')){
    $u=[Environment]::GetEnvironmentVariable($name,'User')
    $m=[Environment]::GetEnvironmentVariable($name,'Machine')
    if($u){ Say "$name is set in User environment (RouteGuard leaves it untouched)." 'Yellow' }
    if($m){ Say "$name is set in Machine environment (RouteGuard leaves it untouched)." 'Yellow' }
  }

  foreach($base in @('Antigravity','Antigravity IDE')){
    $settings=Join-Path $env:APPDATA "$base\User\settings.json"
    if(!(Test-Path $settings)){ continue }
    try {
      $raw=Get-Content $settings -Raw -Encoding UTF8
      if($raw -match '"http\.proxy"\s*:'){
        Say "$base settings.json contains http.proxy; it can create a second proxy path." 'Yellow'
      }
      if($raw -match '"jetski\.cloudCodeUrl"\s*:'){
        Say "$base settings.json contains jetski.cloudCodeUrl; endpoint override detected." 'Yellow'
      }
    } catch {}
  }
}

function Do-Status {
  Say "AG RouteGuard v$Version" 'Magenta'
  Say "Bridge process: $(@(Get-BridgeProcess).Count -gt 0)" 'Cyan'
  if(Test-Path $PendingRepair){ Say 'Pending repair: YES (will apply when Antigravity is closed).' 'Yellow' }
  if(Test-Path $PendingUpdate){ Say 'Pending RouteGuard update: YES (will apply when Antigravity is closed).' 'Yellow' }
  Say "Patch current: $(Test-PatchCurrent)" 'Cyan'
  Show-CompetingProxySettings
  Show-LiveLanguageServerEgress
  Show-InjectorDiagnostics
  Show-BridgeDiagnostics
  if(Test-Path $ProxyCfg){
    try {
      Check-Egress | Out-Null
      Check-GooglePath | Out-Null
    } catch { Say $_.Exception.Message 'Red' }
  } else { Say 'Proxy not configured.' 'Yellow' }

  try {
    $dir=Get-InstallDir
    Say "Antigravity: $dir" 'Cyan'
    Say "version.dll installed: $([bool](Test-Path (Join-Path $dir 'version.dll')))" 'Cyan'
    foreach($e in @(Test-EligibilityPatch $dir)){
      if($e.patched){ $state='patched'; $color='Green' }
      elseif($e.stock){ $state='stock/unpatched'; $color='Red' }
      else { $state='signature absent'; $color='Yellow' }
      Say "Eligibility $state : $($e.path)" $color
      if($e.machineGate -eq 'patched'){ Say "  machine gate: patched" 'Green' }
      elseif($e.machineGate -eq 'unpatched'){ Say "  machine gate: known + unpatched" 'Red' }
      elseif($e.machineGate -in @('unknown','ambiguous')){ Say "  machine gate: $($e.machineGate) (left untouched; no offset guessing)" 'Yellow' }
    }
  } catch { Say $_.Exception.Message 'Red' }

  $rules=@(Get-OurNrptRules)
  $ruleColor=if($rules.Count -ge 2){'Green'}else{'Yellow'}
  Say "RouteGuard NRPT rules: $($rules.Count)/2" $ruleColor

  if(Get-Process agbridge -ErrorAction SilentlyContinue){ Test-GateDns | Out-Null }

  Test-GateListeners | Out-Null

  $loc=Get-Location400Status
  if($loc){
    if($loc.location400){ Say "Latest agent log STILL has Google location 400: $($loc.path)" 'Red' }
    else { Say "No location 400 found in the latest log tail: $($loc.path)" 'Green' }
    if($loc.accountIneligible -and $loc.account403){ Say 'SERVER ACCOUNT GATE: 403/ineligible is present; this is account entitlement/provisioning, not just IP routing.' 'Red' }
    elseif($loc.accountIneligible){ Say 'Latest log also contains an eligibility/account-region message.' 'Yellow' }
    if($loc.quota429){ Say 'Quota state: 429/RESOURCE_EXHAUSTED is present.' 'Yellow' }
    if($loc.license3501){ Say 'License state: #3501/invalid product license is present.' 'Red' }
    if($loc.proxyBypass){ Say 'Latest log contains proxy/connect errors.' 'Yellow' }
  } else {
    Say 'No Antigravity agent log found yet.' 'Yellow'
  }

  Say 'Server-side Google account country is not rewritten by RouteGuard; local eligibility gates and network egress are separate layers.' 'DarkYellow'
}

function Restore-EligibilityBackups {
  if(!(Test-Path $BackupDir)){ return }
  foreach($metaFile in @(Get-ChildItem $BackupDir -Filter '*.json' -File -ErrorAction SilentlyContinue)){
    try {
      $m=Get-Content $metaFile.FullName -Raw | ConvertFrom-Json
      if(!(Test-Path $m.target) -or !(Test-Path $m.backup)){ continue }
      $current=(Get-FileHash $m.target -Algorithm SHA256).Hash
      if($m.patched_hash -and $current -eq $m.patched_hash){
        Copy-Item $m.backup $m.target -Force
        Say "Restored eligibility backup: $($m.target)" 'Green'
      } else {
        Say "Skipped stale backup (target changed since patch): $($m.target)" 'Yellow'
      }
    } catch {}
  }
}

function Do-Restore {
  Ensure-AdminInteractive
  Assert-AntigravityClosed
  Stop-BridgeNow
  Remove-Tasks
  Remove-GateNrpt
  Remove-PrivateProxyEnv
  Restore-EligibilityBackups
  $managedProcessed=Restore-ManagedFiles

  # Compatibility with pre-0.4 installs which used simple one-off backups.
  if($managedProcessed -eq 0 -and (Test-Path $InstallDirFile)){
    $dir=(Get-Content $InstallDirFile -Raw).Trim()
    $safeLeaf = (Split-Path $dir -Leaf) -replace '[^A-Za-z0-9._-]','_'
    foreach($name in @('version.dll','config.json')){
      $dst=Join-Path $dir $name
      $bak=Join-Path $Root ("backup-$safeLeaf-$name")
      if(Test-Path $bak){ Copy-Item $bak $dst -Force }
      elseif(Test-Path $dst){ Remove-Item $dst -Force }
    }
  }
  Remove-Item $PendingRepair,$PendingUpdate,$LastUpdateCheck -Force -ErrorAction SilentlyContinue
  Say 'Restored eligibility backups, removed gate DNS rules and RouteGuard scheduled tasks.' 'Green'
}

function Parse-Checksum($text,$fileName) {
  foreach($line in ($text -split "`r?`n")){
    if($line -match '^([0-9a-fA-F]{64})\s+\*?(.+)$'){
      if($matches[2].Trim() -eq $fileName){ return $matches[1].ToLowerInvariant() }
    }
  }
  return $null
}

function Do-Update([switch]$Automatic) {
  Ensure-Root
  if(@(Get-AntigravityProcesses).Count -gt 0){
    Set-Content $PendingUpdate (Get-Date -Format o) -Encoding ASCII
    if(-not $Automatic){ Say 'Update deferred safely: close Antigravity; watchdog will apply it automatically.' 'Yellow' }
    return
  }

  $api="https://api.github.com/repos/$Repo/releases/latest"
  try { $rel=Invoke-RestMethod $api -Headers @{ 'User-Agent'="AGRouteGuard/$Version" } }
  catch {
    if($Automatic){ Set-Content $LastUpdateCheck (Get-Date -Format o) -Encoding ASCII; return }
    throw "Update check failed: $($_.Exception.Message)"
  }
  Set-Content $LastUpdateCheck (Get-Date -Format o) -Encoding ASCII

  $zipAsset = $rel.assets | Where-Object { $_.name -eq 'AGRouteGuard-win-x64.zip' } | Select-Object -First 1
  $sumAsset = $rel.assets | Where-Object { $_.name -eq 'SHA256SUMS.txt' } | Select-Object -First 1
  if(!$zipAsset -or !$sumAsset){
    if($Automatic){ return }
    throw 'Latest release is missing package/checksum assets.'
  }

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

    if(Test-Path $InstalledReleaseHash){
      $installed=(Get-Content $InstalledReleaseHash -Raw).Trim().ToLowerInvariant()
      if($installed -eq $actual){
        Remove-Item $PendingUpdate -Force -ErrorAction SilentlyContinue
        if(-not $Automatic){ Say 'RouteGuard is already on the latest rolling release.' 'Green' }
        return
      }
    }

    $unpack = Join-Path $temp 'unpack'
    Expand-Archive $zip $unpack -Force
    foreach($name in @('AGRouteGuard.ps1','agbridge.exe','version.dll','Start-Bridge.ps1')){
      if(!(Test-Path (Join-Path $unpack $name))){ throw "Release package missing $name" }
    }

    Stop-BridgeNow
    foreach($name in @('AGRouteGuard.ps1','agbridge.exe','version.dll','Start-Bridge.ps1')){
      Copy-Item (Join-Path $unpack $name) (Join-Path $Root $name) -Force
    }
    Set-Content $InstalledReleaseHash $actual -Encoding ASCII
    Remove-Item $PendingUpdate -Force -ErrorAction SilentlyContinue

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $InstalledScript -Action Repair
    if(-not $Automatic){ Say 'RouteGuard updated, checksum verified, and repaired.' 'Green' }
  } catch {
    if($Automatic){
      "$(Get-Date -Format o) auto-update: $($_.Exception.Message)" | Add-Content (Join-Path $Root 'watchdog.log') -Encoding UTF8
      return
    }
    throw
  } finally {
    Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Do-Report {
  Ensure-Root
  $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
  $desktop=[Environment]::GetFolderPath('Desktop')
  if([string]::IsNullOrWhiteSpace($desktop)){ $desktop=$Root }
  $path=Join-Path $desktop "AGRouteGuard-report-$stamp.txt"

  $header=@(
    "AG RouteGuard diagnostic report",
    "Generated: $(Get-Date -Format o)",
    "RouteGuard script version: $Version",
    "PowerShell: $($PSVersionTable.PSVersion)",
    "Windows: $([Environment]::OSVersion.VersionString)",
    ""
  ) -join [Environment]::NewLine

  $scriptToRun=if(Test-Path $InstalledScript){$InstalledScript}else{$PSCommandPath}
  $status=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptToRun -Action Status *>&1 | Out-String
  Set-Content -LiteralPath $path -Value ($header + $status) -Encoding UTF8
  Say "Sanitized diagnostic report saved: $path" 'Green'
  Say 'The report does not include the stored proxy password or raw Antigravity conversation logs.' 'Cyan'
}

function Menu {
  Write-Host ''
  Say "AG RouteGuard v$Version" 'Magenta'
  Write-Host '1) Setup   2) Repair   3) Status   4) Reconfigure proxy   5) Update   6) Restore   7) Report   0) Exit'
  switch(Read-Host 'Choose'){
    '1'{Do-Setup}
    '2'{Do-Repair}
    '3'{Do-Status}
    '4'{Do-Reconfigure}
    '5'{Do-Update}
    '6'{Do-Restore}
    '7'{Do-Report}
    default{ }
  }
}

switch($Action){
  'Setup'{Do-Setup}
  'Repair'{Do-Repair}
  'Status'{Do-Status}
  'Report'{Do-Report}
  'Restore'{Do-Restore}
  'Update'{Do-Update}
  'AutoUpdate'{Do-Update -Automatic}
  'Watchdog'{Do-Watchdog}
  'Reconfigure'{Do-Reconfigure}
  default{Menu}
}
