# enhanced-glab installer: copies glab.cmd, glab and glab-accounts.ps1 into a folder that comes BEFORE the real glab on PATH.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1                 # into %USERPROFILE%\.local\bin
#   powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Dir C:\tools  # elsewhere
#
# It changes nothing else: no PATH edit, no profile edit. It tells you what to do if the folder is missing from PATH or comes after glab.
param([string]$Dir = (Join-Path $env:USERPROFILE '.local\bin'))
$ErrorActionPreference = 'Stop'

$real = Get-Command glab.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $real) { Write-Warning 'glab.exe is not on PATH yet: install glab first (winget install GLab.GLab), then run this again.' }

New-Item -ItemType Directory -Force -Path $Dir | Out-Null
foreach ($file in 'glab.cmd', 'glab', 'glab-accounts.ps1') { Copy-Item -Force (Join-Path $PSScriptRoot $file) (Join-Path $Dir $file) }
Write-Host "Copied glab.cmd, glab and glab-accounts.ps1 to $Dir"

# Is $Dir on PATH, and before the real glab?
$full = (Resolve-Path $Dir).Path.TrimEnd('\')
$paths = @($env:Path -split ';' | Where-Object { $_ } | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\') })
$mine = [Array]::FindIndex([string[]]$paths, [Predicate[string]] { param($p) $p -ieq $full })
$theirs = if ($real) { [Array]::FindIndex([string[]]$paths, [Predicate[string]] { param($p) $p -ieq (Split-Path $real.Source).TrimEnd('\') }) } else { -1 }
if ($mine -lt 0) {
  Write-Warning "$Dir is not on PATH. Add it (Settings > System > About > Advanced system settings > Environment Variables > Path), before glab's folder, then open a new terminal."
} elseif ($theirs -ge 0 -and $mine -gt $theirs) {
  Write-Warning "$Dir comes AFTER glab's folder ($(Split-Path $real.Source)) on PATH: move it up, or `glab` will still run the original."
} else {
  Write-Host 'Done. In a new terminal: glab add <name>, glab list, glab use <name>.'
}
