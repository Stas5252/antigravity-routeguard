$ErrorActionPreference='Stop'

function Assert([bool]$Condition,[string]$Message){
  if(-not $Condition){ throw "SELFTEST FAILED: $Message" }
}

$enc=[Text.Encoding]::GetEncoding(28591)
$rx=[Text.RegularExpressions.RegexOptions]::Singleline

$stockPattern="\x48\x85\xc0\x0f\x84....\x80\x78\x08\x00\x0f\x85...."
$patchedPattern="\x48\x85\xc0\x0f\x84....\x48\x85\xc0\x90\x0f\x85...."

[byte[]]$stock=@(
  0x48,0x85,0xc0,0x0f,0x84,0x11,0x22,0x33,0x44,
  0x80,0x78,0x08,0x00,0x0f,0x85,0x55,0x66,0x77,0x88
)
$one=$enc.GetString($stock)
Assert ([regex]::Matches($one,$stockPattern,$rx).Count -eq 1) 'CLI x64 stock core must match once'

$two=$one + $enc.GetString([byte[]](0x90,0x90)) + $one
$matches=@([regex]::Matches($two,$stockPattern,$rx))
Assert ($matches.Count -eq 2) 'CLI x64 duplicate gate must expose both matches'

[byte[]]$bytes=$enc.GetBytes($two)
$fix=[byte[]](0x48,0x85,0xc0,0x90)
foreach($m in $matches){ [Array]::Copy($fix,0,$bytes,$m.Index+9,$fix.Length) }
$after=$enc.GetString($bytes)
Assert ([regex]::Matches($after,$stockPattern,$rx).Count -eq 0) 'all stock CLI gates must be gone after patch'
Assert ([regex]::Matches($after,$patchedPattern,$rx).Count -eq 2) 'all duplicate CLI gates must be patched'

$managerStock="\x80\x78\x08\x00\x74.\x48\x8b.\x24.\x48\x89.\x60"
$managerPatched="\xc6\x40\x08\x01\x90\x90\x48\x8b.\x24.\x48\x89.\x60"
[byte[]]$manager=@(0x80,0x78,0x08,0x00,0x74,0x05,0x48,0x8b,0x44,0x24,0x30,0x48,0x89,0x5c,0x60)
$mtext=$enc.GetString($manager)
Assert ([regex]::Matches($mtext,$managerStock,$rx).Count -eq 1) 'manager stock gate must match'
[byte[]]$mfix=@(0xc6,0x40,0x08,0x01,0x90,0x90)
[Array]::Copy($mfix,0,$manager,0,$mfix.Length)
$mtext2=$enc.GetString($manager)
Assert ([regex]::Matches($mtext2,$managerPatched,$rx).Count -eq 1) 'manager patched gate must verify'

$idePattern='(resetIsTierGCPTos\(\),)this\.[A-Za-z_$0-9]+\.isGoogleInternal'
$ide='abc resetIsTierGCPTos(),this.x7.isGoogleInternal xyz'
$ideMatches=@([regex]::Matches($ide,$idePattern))
Assert ($ideMatches.Count -eq 1) 'IDE gate must be unique in normal fixture'
$ideAfter=[regex]::Replace($ide,$idePattern,'${1}true',1)
Assert ($ideAfter.Contains('resetIsTierGCPTos(),true')) 'IDE replacement must produce successful local branch'

Write-Host 'Eligibility signature self-test: PASS'
