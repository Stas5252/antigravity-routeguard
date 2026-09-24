$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
$scriptPath = Join-Path $root 'AGRouteGuard.ps1'
$readmePath = Join-Path $root 'README.md'
$layerPath = Join-Path $root 'docs\LAYER_MODEL.md'

$script = Get-Content $scriptPath -Raw
$readme = Get-Content $readmePath -Raw
$layer = Get-Content $layerPath -Raw

$m = [regex]::Match($script, '\$Version\s*=\s*''([^'']+)''')
if(-not $m.Success){ throw 'Could not read $Version from AGRouteGuard.ps1' }
$version = $m.Groups[1].Value

if($readme -notmatch [regex]::Escape("Current release line: **$version**.")){
  throw "README release line does not match AGRouteGuard.ps1 version $version"
}

$majorMinor = ($version -split '\.')[0..1] -join '.'
if($layer -notmatch "RouteGuard\s+$([regex]::Escape($majorMinor))(?:\.\d+)?\s+mirrors"){
  throw "docs/LAYER_MODEL.md does not mention current RouteGuard $majorMinor.x line"
}

Write-Host "Version metadata is consistent: $version"
