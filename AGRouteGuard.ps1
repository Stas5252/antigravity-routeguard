param(
  [ValidateSet('Menu','Setup','Repair','Status','Restore','Update','Watchdog','Reconfigure')]
  [string]$Action = 'Menu'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Version = '0.3.0'
$Repo = 'Stas5252/antigravity-routeguard'
$Root = Join-Path $env:LOCALAPPDATA 'AGRouteGuard'
$BackupDir = Join-Path $Root 'backups'
$ProxyCfg = Join-Path $Root 'proxy.json'
$Bridge = Join-Path $Root 'agbridge.exe'
$Injector = Join-Path $Root 'version.dll'
$StartBridge = Join-Path $Root 'Start-Bridge.ps1'
$InstalledScript = Join-Path $Root 'AGRouteGuard.ps1'
$InstallDirFile = Join-Path $Root 'install-dir.txt'
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

function Get-InstallDir {
  return (Split-Path (Find-Antigravity) -Parent)
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
  $cliPattern="\x48\x85\xc0\x0f\x84....\x80\x78\x08\x00\x0f\x85...."
  $cliPatched="\x48\x85\xc0\x0f\x84....\x48\x85\xc0\x90\x0f\x85...."
  $managerPattern="\x80\x78\x08\x00\x74.\x48\x8b.\x24.\x48\x89.\x60"
  $managerPatched="\xc6\x40\x08\x01\x90\x90\x48\x8b.\x24.\x48\x89.\x60"

  $cliMatches=@()
  $managerMatches=@()
  $hasCliGate=$false
  $hasManagerGate=$false

  if($name -eq 'agy.exe'){
    $cliMatches=@([regex]::Matches($latin,$cliPattern,$rxOpt))
    $hasCliGate=[regex]::IsMatch($latin,$cliPatched,$rxOpt)
  }
  if($name.StartsWith('language_server')){
    $managerMatches=@([regex]::Matches($latin,$managerPattern,$rxOpt))
    $hasManagerGate=[regex]::IsMatch($latin,$managerPatched,$rxOpt)
  }

  $needCliGate=$cliMatches.Count -gt 0
  $needManagerGate=$managerMatches.Count -eq 1
  $managerAmbiguous=$managerMatches.Count -gt 1

  $anyChange=$needEligibility -or $needProxyVar -or $needCliGate -or $needManagerGate
  if(-not $anyChange){
    if($hasEligibility -or $hasProxyVar -or $hasCliGate -or $hasManagerGate){
      if(-not $Quiet){ Say "Client binary gates already patched: $path" 'DarkGreen' }
      return $true
    }
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
    foreach($m in $cliMatches){ [Array]::Copy($fix,0,$bytes,$m.Index+9,$fix.Length) }
    $changes += "agy eligibility gate x$($cliMatches.Count)"
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
  foreach($p in @(Get-EligibilityTargets $installDir)){
    try {
      $s=[Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($p))
      $results += [pscustomobject]@{
        path=$p
        patched=$s.Contains('inexigible')
        stock=$s.Contains('ineligible')
        privateProxy=$s.Contains('AG_LS_PROXY')
        stockProxy=$s.Contains('https_proxy')
      }
    } catch {}
  }
  return $results
}

function Apply-Patch([switch]$Quiet) {
  if(!(Test-Path $Injector)){ throw 'version.dll payload missing. Run Setup/Repair from the release package.' }
  $dir=Get-InstallDir
  Backup-IfNeeded $dir 'version.dll'
  Backup-IfNeeded $dir 'config.json'

  Copy-Item $Injector (Join-Path $dir 'version.dll') -Force
  Write-InjectorConfig $dir
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
    if(@($elig | Where-Object { ($_.stock -and -not $_.patched) -or ($_.stockProxy -and -not $_.privateProxy) }).Count -gt 0){ return $false }
    return $true
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
      proxyBypass=($tail -match 'proxyconnect|connectex|connection refused')
    }
  } catch { return $null }
}

function Do-Setup {
  Ensure-AdminInteractive
  Install-Files
  Save-Proxy
  Check-Egress | Out-Null
  Start-BridgeNow
  Ensure-GateNrpt | Out-Null
  if(-not (Test-GateDns)){ throw 'Gate DNS self-test failed. Do not launch Antigravity until Status is green.' }
  Apply-Patch
  Register-Tasks
  Say 'Setup complete. Close Antigravity completely, then open it again.' 'Green'
  Say 'Happ/TUN is not required for this setup. Test RouteGuard alone first.' 'Yellow'
}

function Do-Reconfigure {
  Ensure-AdminInteractive
  Install-Files
  Save-Proxy
  Check-Egress | Out-Null
  Stop-Process -Name agbridge -Force -ErrorAction SilentlyContinue
  Start-BridgeNow
  Ensure-GateNrpt | Out-Null
  Apply-Patch
  Register-Tasks
  Say 'Proxy changed and RouteGuard repaired.' 'Green'
}

function Do-Repair([switch]$Quiet) {
  if(Test-Path (Join-Path $PSScriptRoot 'agbridge.exe')){ Install-Files }
  Start-BridgeNow
  Check-Egress -Quiet | Out-Null
  if(Test-IsAdmin){ Ensure-GateNrpt -Quiet | Out-Null }
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
    $dir=Get-InstallDir
    Say "Antigravity: $dir" 'Cyan'
    Say "version.dll installed: $([bool](Test-Path (Join-Path $dir 'version.dll')))" 'Cyan'
    foreach($e in @(Test-EligibilityPatch $dir)){
      if($e.patched){ $state='patched'; $color='Green' }
      elseif($e.stock){ $state='stock/unpatched'; $color='Red' }
      else { $state='signature absent'; $color='Yellow' }
      Say "Eligibility $state : $($e.path)" $color
    }
  } catch { Say $_.Exception.Message 'Red' }

  $rules=@(Get-OurNrptRules)
  $ruleColor=if($rules.Count -ge 2){'Green'}else{'Yellow'}
  Say "RouteGuard NRPT rules: $($rules.Count)/2" $ruleColor

  if(Get-Process agbridge -ErrorAction SilentlyContinue){ Test-GateDns | Out-Null }

  foreach($host in $GateMap.Keys){
    $ip=$GateMap[$host]
    try {
      $tcp=Test-NetConnection $ip -Port 443 -WarningAction SilentlyContinue
      $tcpColor=if($tcp.TcpTestSucceeded){'Green'}else{'Red'}
      Say "Gate TCP $host via $($ip):443 = $($tcp.TcpTestSucceeded)" $tcpColor
    } catch {}
  }

  $loc=Get-Location400Status
  if($loc){
    if($loc.location400){ Say "Latest agent log STILL has Google location 400: $($loc.path)" 'Red' }
    else { Say "No location 400 found in the latest log tail: $($loc.path)" 'Green' }
    if($loc.accountIneligible){ Say 'Latest log also contains an eligibility/account-region message.' 'Yellow' }
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
  Stop-Process -Name agbridge -Force -ErrorAction SilentlyContinue
  Remove-Tasks
  Remove-GateNrpt
  Remove-PrivateProxyEnv
  Restore-EligibilityBackups
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
