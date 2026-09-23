# Eligibility / region / deterministic CloudCode routing helpers for AG RouteGuard.
# This file is intentionally PowerShell-only so every edit is auditable.

$script:RG_GateProxyUrl = 'http://127.0.0.1:17891'
$script:RG_HostsBegin = '# BEGIN AG ROUTEGUARD'
$script:RG_HostsEnd   = '# END AG ROUTEGUARD'
$script:RG_GateHosts = @(
  '127.65.71.1 cloudcode-pa.googleapis.com',
  '127.65.71.2 daily-cloudcode-pa.googleapis.com'
)

function Get-RGFileSha([string]$Path) {
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-RGPatchedBytes {
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][byte[]]$Bytes,
    [Parameter(Mandatory=$true)][string]$Kind
  )
  $origSha = Get-RGFileSha $Path
  $backup = "$Path.agrouteguard.$($origSha.Substring(0,16)).bak"
  if (!(Test-Path -LiteralPath $backup)) {
    Copy-Item -LiteralPath $Path -Destination $backup -Force
  }

  $tmp = "$Path.agrouteguard.tmp-$PID"
  [IO.File]::WriteAllBytes($tmp, $Bytes)
  try {
    [IO.File]::Replace($tmp, $Path, $null)
  } catch {
    Move-Item -LiteralPath $tmp -Destination $Path -Force
  }

  $patchedSha = Get-RGFileSha $Path
  [pscustomobject]@{
    kind = $Kind
    backup = $backup
    original_sha256 = $origSha
    patched_sha256 = $patchedSha
    utc = [DateTime]::UtcNow.ToString('o')
  } | ConvertTo-Json | Set-Content -LiteralPath "$Path.agrouteguard.meta.json" -Encoding UTF8
}

function Restore-RGPatchedFile {
  param([Parameter(Mandatory=$true)][string]$Path)

  $metaPath = "$Path.agrouteguard.meta.json"
  if (!(Test-Path -LiteralPath $metaPath)) { return $false }

  try { $meta = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json }
  catch { return $false }

  if (!(Test-Path -LiteralPath $meta.backup)) { return $false }
  if (!(Test-Path -LiteralPath $Path)) { return $false }

  $current = Get-RGFileSha $Path
  if ($current -ne [string]$meta.patched_sha256) {
    # An app update already replaced our patched file. Never overwrite a newer
    # application build with an old backup.
    return $false
  }

  Copy-Item -LiteralPath $meta.backup -Destination $Path -Force
  Remove-Item -LiteralPath $metaPath -Force -ErrorAction SilentlyContinue
  return $true
}

function Get-RGNativeTargets {
  param([Parameter(Mandatory=$true)][string]$InstallDir)

  $out = New-Object System.Collections.Generic.List[string]
  foreach($p in @(
    (Join-Path $InstallDir 'agy.exe'),
    (Join-Path $InstallDir 'resources\bin\language_server.exe'),
    (Join-Path $InstallDir 'resources\app\extensions\antigravity\bin\language_server_windows_x64.exe'),
    (Join-Path $InstallDir 'resources\app\extensions\antigravity\bin\language_server.exe')
  )) {
    if (Test-Path -LiteralPath $p) { [void]$out.Add($p) }
  }

  foreach($dir in @(
    (Join-Path $InstallDir 'resources\bin'),
    (Join-Path $InstallDir 'resources\app\extensions\antigravity\bin')
  )) {
    if (Test-Path -LiteralPath $dir) {
      Get-ChildItem -LiteralPath $dir -Filter 'language_server*.exe' -File -ErrorAction SilentlyContinue |
        ForEach-Object { if (!$out.Contains($_.FullName)) { [void]$out.Add($_.FullName) } }
    }
  }
  return @($out | Select-Object -Unique)
}

function Patch-RGNativeEligibility {
  param([Parameter(Mandatory=$true)][string]$InstallDir)

  $latin1 = [Text.Encoding]::GetEncoding(28591)
  $patched = 0
  $already = 0
  $unsupported = 0

  foreach($path in Get-RGNativeTargets $InstallDir) {
    try {
      $bytes = [IO.File]::ReadAllBytes($path)
      $text = $latin1.GetString($bytes)
      $needsEligibility = $text.Contains('ineligible')
      $needsPrivateProxy = $text.Contains('https_proxy')
      $alreadyEligibility = $text.Contains('inexigible')
      $alreadyPrivateProxy = $text.Contains('AG_LS_PROXY')

      if (!$needsEligibility -and !$needsPrivateProxy) {
        if ($alreadyEligibility -or $alreadyPrivateProxy) { $already++ } else { $unsupported++ }
        continue
      }

      # Same-length rewrites used by current unlockers:
      # ineligible -> inexigible hides the client-side eligibility field;
      # https_proxy -> AG_LS_PROXY gives Antigravity a private proxy variable
      # without changing the system-wide HTTPS_PROXY used by git/npm/etc.
      $newText = $text.Replace('ineligible','inexigible').Replace('https_proxy','AG_LS_PROXY')
      if ($newText -eq $text) { continue }

      Stop-Process -Name 'language_server','language_server_windows_x64','agy' -Force -ErrorAction SilentlyContinue
      $newBytes = $latin1.GetBytes($newText)
      Write-RGPatchedBytes -Path $path -Bytes $newBytes -Kind 'native-eligibility'
      $patched++
    } catch {
      Write-Warning "Native eligibility patch failed for $path : $($_.Exception.Message)"
    }
  }

  [pscustomobject]@{ patched=$patched; already=$already; unsupported=$unsupported }
}

function Get-RGIdeMainJsTargets {
  param([Parameter(Mandatory=$true)][string]$InstallDir)
  @(
    (Join-Path $InstallDir 'resources\app\out\main.js'),
    (Join-Path $InstallDir 'resources\app\main.js')
  ) | Where-Object { Test-Path -LiteralPath $_ }
}

function Clear-RGJsCache {
  foreach($base in @(
    (Join-Path $env:APPDATA 'Antigravity'),
    (Join-Path $env:APPDATA 'Antigravity IDE')
  )) {
    foreach($rel in @('CachedData','Code Cache\js')) {
      $p = Join-Path $base $rel
      if (Test-Path -LiteralPath $p) {
        Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
      }
    }
  }
}

function Patch-RGIdeEligibility {
  param([Parameter(Mandatory=$true)][string]$InstallDir)

  $pattern = '(resetIsTierGCPTos\(\),)this\.[A-Za-z_$0-9]+\.isGoogleInternal'
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  $changed = 0

  foreach($path in Get-RGIdeMainJsTargets $InstallDir) {
    try {
      $text = [IO.File]::ReadAllText($path)
      if ($text -match 'resetIsTierGCPTos\(\),true') { continue }
      if ($text -notmatch $pattern) { continue }

      $newText = [regex]::Replace($text, $pattern, '$1true')
      if ($newText -eq $text) { continue }
      Write-RGPatchedBytes -Path $path -Bytes ($utf8.GetBytes($newText)) -Kind 'ide-isGoogleInternal'
      $changed++
    } catch {
      Write-Warning "IDE eligibility patch failed for $path : $($_.Exception.Message)"
    }
  }
  if ($changed -gt 0) { Clear-RGJsCache }
  return $changed
}

function Set-RGPrivateProxyVar {
  param([Parameter(Mandatory=$true)][string]$Root)

  $prevFile = Join-Path $Root 'previous-env.json'
  $previous = [Environment]::GetEnvironmentVariable('AG_LS_PROXY','User')
  if (!(Test-Path -LiteralPath $prevFile)) {
    [pscustomobject]@{ AG_LS_PROXY=$previous } | ConvertTo-Json | Set-Content $prevFile -Encoding UTF8
  }

  [Environment]::SetEnvironmentVariable('AG_LS_PROXY',$script:RG_GateProxyUrl,'User')
  $env:AG_LS_PROXY = $script:RG_GateProxyUrl
}

function Restore-RGPrivateProxyVar {
  param([Parameter(Mandatory=$true)][string]$Root)

  $prevFile = Join-Path $Root 'previous-env.json'
  $current = [Environment]::GetEnvironmentVariable('AG_LS_PROXY','User')
  if ($current -ne $script:RG_GateProxyUrl) { return }

  $prev = $null
  if (Test-Path -LiteralPath $prevFile) {
    try { $prev = (Get-Content $prevFile -Raw | ConvertFrom-Json).AG_LS_PROXY } catch {}
  }
  [Environment]::SetEnvironmentVariable('AG_LS_PROXY',$prev,'User')
  if ($null -eq $prev) { Remove-Item Env:AG_LS_PROXY -ErrorAction SilentlyContinue } else { $env:AG_LS_PROXY=$prev }
}

function Test-RGIsAdmin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-RGGateHosts {
  $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
  if (!(Test-RGIsAdmin)) { throw 'Administrator rights are required once to install exact CloudCode gate routing.' }

  $raw = [IO.File]::ReadAllText($hostsPath)
  $begin = [regex]::Escape($script:RG_HostsBegin)
  $end = [regex]::Escape($script:RG_HostsEnd)
  $clean = [regex]::Replace($raw, "(?ms)^$begin\r?\n.*?^$end\r?\n?", '')
  if (!$clean.EndsWith([Environment]::NewLine)) { $clean += [Environment]::NewLine }

  $block = $script:RG_HostsBegin + [Environment]::NewLine +
           ($script:RG_GateHosts -join [Environment]::NewLine) + [Environment]::NewLine +
           $script:RG_HostsEnd + [Environment]::NewLine
  [IO.File]::WriteAllText($hostsPath, $clean + $block, [Text.Encoding]::ASCII)
  ipconfig /flushdns | Out-Null
}

function Remove-RGGateHosts {
  $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
  if (!(Test-Path -LiteralPath $hostsPath)) { return }
  if (!(Test-RGIsAdmin)) { throw 'Administrator rights are required to remove RouteGuard hosts entries.' }

  $raw = [IO.File]::ReadAllText($hostsPath)
  $begin = [regex]::Escape($script:RG_HostsBegin)
  $end = [regex]::Escape($script:RG_HostsEnd)
  $clean = [regex]::Replace($raw, "(?ms)^$begin\r?\n.*?^$end\r?\n?", '')
  [IO.File]::WriteAllText($hostsPath, $clean, [Text.Encoding]::ASCII)
  ipconfig /flushdns | Out-Null
}

function Test-RGGateHosts {
  $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
  if (!(Test-Path -LiteralPath $hostsPath)) { return $false }
  $raw = [IO.File]::ReadAllText($hostsPath)
  return ($raw.Contains('127.65.71.1 cloudcode-pa.googleapis.com') -and
          $raw.Contains('127.65.71.2 daily-cloudcode-pa.googleapis.com'))
}

function Repair-RGEligibility {
  param(
    [Parameter(Mandatory=$true)][string]$InstallDir,
    [Parameter(Mandatory=$true)][string]$Root,
    [switch]$EnsureHosts
  )

  Set-RGPrivateProxyVar -Root $Root
  $native = Patch-RGNativeEligibility -InstallDir $InstallDir
  $ide = Patch-RGIdeEligibility -InstallDir $InstallDir

  if ($EnsureHosts) { Ensure-RGGateHosts }

  [pscustomobject]@{
    native = $native
    ide_js_patched = $ide
    private_proxy = [Environment]::GetEnvironmentVariable('AG_LS_PROXY','User')
    gate_hosts = Test-RGGateHosts
  }
}

function Get-RGEligibilityStatus {
  param([Parameter(Mandatory=$true)][string]$InstallDir)

  $latin1 = [Text.Encoding]::GetEncoding(28591)
  $targets = Get-RGNativeTargets $InstallDir
  $nativePatched = 0
  $nativeOriginal = 0
  $unknown = 0

  foreach($path in $targets) {
    try {
      $text = $latin1.GetString([IO.File]::ReadAllBytes($path))
      if ($text.Contains('inexigible') -and $text.Contains('AG_LS_PROXY')) { $nativePatched++ }
      elseif ($text.Contains('ineligible') -or $text.Contains('https_proxy')) { $nativeOriginal++ }
      else { $unknown++ }
    } catch { $unknown++ }
  }

  $ideState = 'not-applicable'
  foreach($path in Get-RGIdeMainJsTargets $InstallDir) {
    try {
      $text = [IO.File]::ReadAllText($path)
      if ($text -match 'resetIsTierGCPTos\(\),true') { $ideState='patched'; break }
      if ($text -match 'resetIsTierGCPTos\(\),this\.[A-Za-z_$0-9]+\.isGoogleInternal') { $ideState='unpatched' }
    } catch {}
  }

  [pscustomobject]@{
    native_targets = $targets.Count
    native_patched = $nativePatched
    native_unpatched = $nativeOriginal
    native_unknown = $unknown
    ide = $ideState
    private_proxy = [Environment]::GetEnvironmentVariable('AG_LS_PROXY','User')
    gate_hosts = Test-RGGateHosts
  }
}

function Restore-RGEligibility {
  param(
    [Parameter(Mandatory=$true)][string]$InstallDir,
    [Parameter(Mandatory=$true)][string]$Root
  )

  Stop-Process -Name 'language_server','language_server_windows_x64','agy' -Force -ErrorAction SilentlyContinue
  $restored = 0

  foreach($path in Get-RGNativeTargets $InstallDir) {
    if (Restore-RGPatchedFile -Path $path) { $restored++ }
  }
  foreach($path in Get-RGIdeMainJsTargets $InstallDir) {
    if (Restore-RGPatchedFile -Path $path) { $restored++ }
  }

  Restore-RGPrivateProxyVar -Root $Root
  Remove-RGGateHosts
  Clear-RGJsCache
  return $restored
}
