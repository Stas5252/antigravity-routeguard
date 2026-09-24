$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

param()

function Say([string]$m,[string]$c='Gray'){ Write-Host $m -ForegroundColor $c }

function Get-ToolsDataDirs {
  $dirs = New-Object System.Collections.Generic.List[string]

  if($env:ABV_DATA_DIR -and (Test-Path -LiteralPath $env:ABV_DATA_DIR)){
    [void]$dirs.Add([IO.Path]::GetFullPath($env:ABV_DATA_DIR))
  }

  $homePointer = Join-Path $env:USERPROFILE '.antigravity_tools_location'
  if(Test-Path -LiteralPath $homePointer){
    try {
      $p=(Get-Content -LiteralPath $homePointer -Raw).Trim().Trim('"')
      if($p -and (Test-Path -LiteralPath $p)){ [void]$dirs.Add([IO.Path]::GetFullPath($p)) }
    } catch {}
  }

  $configPointer = Join-Path $env:APPDATA 'antigravity-tools\data_dir.txt'
  if(Test-Path -LiteralPath $configPointer){
    try {
      $p=(Get-Content -LiteralPath $configPointer -Raw).Trim().Trim('"')
      if($p -and (Test-Path -LiteralPath $p)){ [void]$dirs.Add([IO.Path]::GetFullPath($p)) }
    } catch {}
  }

  $default = Join-Path $env:USERPROFILE '.antigravity_tools'
  if(Test-Path -LiteralPath $default){ [void]$dirs.Add([IO.Path]::GetFullPath($default)) }

  return @($dirs | Select-Object -Unique)
}

function Get-ToolsApiPorts {
  $ports = New-Object System.Collections.Generic.List[int]
  [void]$ports.Add(19527)

  foreach($dir in @(Get-ToolsDataDirs)){
    $settings = Join-Path $dir 'http_api_settings.json'
    if(!(Test-Path -LiteralPath $settings)){ continue }
    try {
      $j = Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json
      if($j.enabled -eq $false){ continue }
      $p=[int]$j.port
      if($p -ge 1024 -and $p -le 65535 -and -not $ports.Contains($p)){ [void]$ports.Add($p) }
    } catch {}
  }

  return @($ports)
}

function Find-ToolsApi {
  foreach($port in @(Get-ToolsApiPorts)){
    $base="http://127.0.0.1:$port"
    try {
      $h=Invoke-RestMethod -Uri "$base/health" -Method Get -TimeoutSec 2
      if($h.status -eq 'ok'){ return $base }
    } catch {}
  }
  return $null
}

function Get-Accounts([string]$base) {
  $r=Invoke-RestMethod -Uri "$base/accounts" -Method Get -TimeoutSec 5
  if($null -eq $r.accounts){ throw 'Antigravity Tools returned an invalid account list.' }
  return $r
}

function Format-Quota($account) {
  try {
    if($null -eq $account.quota -or $null -eq $account.quota.models){ return 'quota ?' }
    $models=@($account.quota.models | Where-Object { $_.name -match 'gemini' })
    if($models.Count -eq 0){ return 'quota ?' }
    $best=($models | Measure-Object -Property percentage -Maximum).Maximum
    return "gemini max $best%"
  } catch { return 'quota ?' }
}

function Show-Accounts($snapshot) {
  Write-Host ''
  Say 'Antigravity Tools accounts' 'Magenta'
  for($i=0; $i -lt @($snapshot.accounts).Count; $i++){
    $a=$snapshot.accounts[$i]
    $current=if($a.id -eq $snapshot.current_account_id){'CURRENT'}else{'       '}
    $disabled=if($a.disabled){' DISABLED'}else{''}
    $quota=Format-Quota $a
    Write-Host ("[{0}] {1}  {2}  {3}{4}" -f ($i+1),$current,$a.email,$quota,$disabled)
  }
  Write-Host ''
}

function Test-RouteGuardBridge {
  try {
    $c=Get-NetTCPConnection -State Listen -LocalPort 17890 -ErrorAction Stop |
      Where-Object { $_.LocalAddress -eq '127.0.0.1' -or $_.LocalAddress -eq '::1' } |
      Select-Object -First 1
    return ($null -ne $c)
  } catch {
    try {
      return (Test-NetConnection 127.0.0.1 -Port 17890 -WarningAction SilentlyContinue).TcpTestSucceeded
    } catch { return $false }
  }
}

function Warn-ToolsProxyPath {
  $found=$false
  foreach($dir in @(Get-ToolsDataDirs)){
    $cfg=Join-Path $dir 'gui_config.json'
    if(!(Test-Path -LiteralPath $cfg)){ continue }
    try {
      $j=Get-Content -LiteralPath $cfg -Raw | ConvertFrom-Json
      $up=$j.proxy.upstream_proxy
      if($null -ne $up){
        $found=$true
        $enabled=[bool]$up.enabled
        $url=[string]$up.url
        if($enabled -and $url -match '^socks5h?://127\.0\.0\.1:17890/?$'){
          Say 'Tools OAuth/account traffic: RouteGuard local bridge.' 'Green'
        } elseif($enabled) {
          Say "Tools upstream proxy points somewhere else: $url" 'Yellow'
          Say 'Recommended for account switching: socks5h://127.0.0.1:17890' 'Yellow'
        } else {
          Say 'Tools upstream proxy is OFF. If a token refresh is needed during account switch, Tools may use its direct network path.' 'Yellow'
          Say 'Recommended: Proxy Pool OFF; Global Upstream Proxy ON -> socks5h://127.0.0.1:17890' 'Yellow'
        }
      }
    } catch {}
  }
  if(-not $found){
    Say 'Could not inspect Antigravity Tools upstream-proxy config.' 'Yellow'
  }
}

function Confirm-RunningSwitch {
  $running=@(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ProcessName -like 'Antigravity*' -or $_.ProcessName -like 'language_server*'
  })
  if($running.Count -eq 0){ return $true }

  Say 'Antigravity is running. Account switching can restart/interrupt the current agent run.' 'Yellow'
  $ans=(Read-Host 'Switch anyway? [y/N]').Trim().ToLowerInvariant()
  return ($ans -eq 'y' -or $ans -eq 'yes')
}

function Wait-ForSwitch([string]$base,[string]$targetId,[int]$seconds=90) {
  for($i=0;$i -lt $seconds;$i++){
    Start-Sleep -Seconds 1
    try {
      $cur=Invoke-RestMethod -Uri "$base/accounts/current" -Method Get -TimeoutSec 3
      if($null -ne $cur.account -and [string]$cur.account.id -eq $targetId){
        return $cur.account
      }
    } catch {}
  }
  throw "Account switch did not become current within $seconds seconds."
}

if(-not (Test-RouteGuardBridge)){
  Say 'RouteGuard bridge is not listening on 127.0.0.1:17890.' 'Red'
  Say 'Run Install/Repair first.' 'Yellow'
  exit 2
}

$base=Find-ToolsApi
if(!$base){
  Say 'Antigravity Tools HTTP API was not found.' 'Red'
  Say 'Start Antigravity Tools and enable Settings -> HTTP API. Default port is 19527.' 'Yellow'
  exit 3
}

Say "Antigravity Tools API: $base" 'Green'
Warn-ToolsProxyPath

$snapshot=Get-Accounts $base
if(@($snapshot.accounts).Count -eq 0){
  Say 'No accounts found in Antigravity Tools.' 'Red'
  exit 4
}

Show-Accounts $snapshot
$choice=(Read-Host 'Choose account number, or press Enter to cancel').Trim()
if([string]::IsNullOrWhiteSpace($choice)){ exit 0 }

$n=0
if(-not [int]::TryParse($choice,[ref]$n) -or $n -lt 1 -or $n -gt @($snapshot.accounts).Count){
  Say 'Invalid account number.' 'Red'
  exit 5
}

$target=$snapshot.accounts[$n-1]
if($target.id -eq $snapshot.current_account_id){
  Say "Already active: $($target.email)" 'Green'
  exit 0
}
if($target.disabled){
  Say "Selected account is marked disabled in Antigravity Tools: $($target.email)" 'Red'
  exit 6
}

if(-not (Confirm-RunningSwitch)){ exit 0 }

Say "Switching to $($target.email)..." 'Cyan'
$body=@{account_id=[string]$target.id} | ConvertTo-Json -Compress
try {
  Invoke-RestMethod -Uri "$base/accounts/switch" -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 10 | Out-Null
} catch {
  throw "Antigravity Tools rejected the switch request: $($_.Exception.Message)"
}

$current=Wait-ForSwitch -base $base -targetId ([string]$target.id)
Say "ACCOUNT SWITCHED: $($current.email)" 'Green'

if(Test-RouteGuardBridge){
  Say 'RouteGuard bridge is still alive after account switch.' 'Green'
} else {
  Say 'RouteGuard bridge is no longer listening after account switch. Run Repair before using Gemini.' 'Red'
  exit 7
}

Say 'If Antigravity did not reopen automatically, use Launch.cmd.' 'Cyan'
