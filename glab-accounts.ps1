# enhanced-glab: several GitLab accounts for glab, with glab's own browser (OAuth) login, and switching between them.
# https://github.com/MedZayd/enhanced-glab (MIT licence).
#
#   glab add <name>     opens GitLab in the browser, like `glab auth login`, and saves that account under <name>
#   glab list           the saved accounts (* = the one glab uses now)
#   glab use <name>     glab now uses that account (everywhere: PowerShell, Git Bash, scripts) until the next `use`
#   glab remove <name>  forgets a saved account (not the one in use)
#
# Launched by glab.cmd (PowerShell, cmd) and glab (Git Bash) next to this file; every other glab command goes to the real glab.exe.
#
# How: glab keeps ONE login per host, in the Windows credential store (« glab:<host>:token: » and « glab:<host>:oauth2_refresh_token: »)
# plus three lines of its config.yml (user, is_oauth2, oauth2_expiry_date). An account here is a copy of that login, its two secrets
# encrypted with DPAPI for this Windows user (%APPDATA%\glab-accounts\<name>.json). `use` first saves the login in use (glab renews its
# OAuth tokens by itself, so the copy must be taken when leaving it), then puts the chosen one in place and asks GitLab who it is. On any
# failure the previous login is put back. Secrets are never printed.

$ErrorActionPreference = 'Stop'
if ([Console]::IsOutputRedirected -or [Console]::IsErrorRedirected) { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false }
# No param() block: PowerShell would take arguments starting with « - » as its own parameters.
$Command = if ($args.Count -gt 0) { [string]$args[0] } else { 'help' }
$Rest = [string[]]@(if ($args.Count -gt 1) { $args[1..($args.Count - 1)] })

# The real glab: GLAB_REAL (the launchers set it), else the first glab.exe on PATH.
$Real = if ($env:GLAB_REAL) { $env:GLAB_REAL } else { (Get-Command glab.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source }
$Store = if ($env:GLAB_ACCOUNTS_DIR) { $env:GLAB_ACCOUNTS_DIR } else { Join-Path $env:APPDATA 'glab-accounts' }
$ConfigFile = if ($env:GLAB_CONFIG_DIR) { Join-Path $env:GLAB_CONFIG_DIR 'config.yml' } else { Join-Path $env:LOCALAPPDATA 'glab-cli\config.yml' }
$NoVerify = $env:GLAB_ACCOUNTS_NO_VERIFY -eq '1'   # tests only (a fake host has no GitLab to ask)

function Fail([string]$Message) { [Console]::Error.WriteLine("glab: $Message"); exit 1 }
function Say([string]$Message) { [Console]::Out.WriteLine($Message) }
if (-not $Real -or -not (Test-Path $Real)) { Fail "the real glab.exe was not found (install glab, or set GLAB_REAL)" }

# ---- the Windows credential store, where glab keeps its secrets -----------------------------------------------------------------------
Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices; using System.Text;
public static class GlabCred {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  struct CREDENTIAL { public int Flags; public int Type; public string TargetName; public string Comment; public long LastWritten;
    public int CredentialBlobSize; public IntPtr CredentialBlob; public int Persist; public int AttributeCount; public IntPtr Attributes;
    public string TargetAlias; public string UserName; }
  [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CredReadW(string target, int type, int flags, out IntPtr cred);
  [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CredWriteW(ref CREDENTIAL cred, int flags);
  [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CredDeleteW(string target, int type, int flags);
  [DllImport("advapi32.dll")] static extern void CredFree(IntPtr p);
  const int GENERIC = 1, NOT_FOUND = 1168, LOCAL_MACHINE = 2;
  public static string Read(string target) {
    IntPtr p;
    if (!CredReadW(target, GENERIC, 0, out p)) { int e = Marshal.GetLastWin32Error(); if (e == NOT_FOUND) return null; throw new Exception("CredRead " + e); }
    try { var c = (CREDENTIAL)Marshal.PtrToStructure(p, typeof(CREDENTIAL)); var b = new byte[c.CredentialBlobSize];
      if (b.Length > 0) Marshal.Copy(c.CredentialBlob, b, 0, b.Length); return Encoding.UTF8.GetString(b); }
    finally { CredFree(p); }
  }
  // As glab writes them (go-keyring): generic, empty user name, the secret's UTF-8 bytes, kept on this computer.
  public static void Write(string target, string value) {
    var b = Encoding.UTF8.GetBytes(value); var h = Marshal.AllocHGlobal(Math.Max(b.Length, 1));
    try { Marshal.Copy(b, 0, h, b.Length);
      var c = new CREDENTIAL { Type = GENERIC, TargetName = target, CredentialBlobSize = b.Length, CredentialBlob = h, Persist = LOCAL_MACHINE, UserName = "" };
      if (!CredWriteW(ref c, 0)) throw new Exception("CredWrite " + Marshal.GetLastWin32Error()); }
    finally { Marshal.FreeHGlobal(h); }
  }
  public static void Delete(string target) {
    if (!CredDeleteW(target, GENERIC, 0)) { int e = Marshal.GetLastWin32Error(); if (e != NOT_FOUND) throw new Exception("CredDelete " + e); }
  }
}
"@
function Target([string]$GitlabHost, [string]$Key) { "glab:${GitlabHost}:${Key}:" }

# ---- glab's config.yml: the three lines of a host's login -------------------------------------------------------------------------------
function Get-HostFields([string]$GitlabHost) {
  $fields = @{}
  if (-not (Test-Path $ConfigFile)) { return $fields }
  $inHosts = $false; $inHost = $false
  foreach ($line in [IO.File]::ReadAllLines($ConfigFile)) {
    if ($line -match '^\S') { $inHosts = ($line -match '^hosts:\s*$'); $inHost = $false; continue }
    if ($inHosts -and $line -match '^ {4}(\S[^:]*):\s*$') { $inHost = ($Matches[1] -eq $GitlabHost); continue }
    if ($inHost -and $line -match '^ {8}([A-Za-z0-9_]+):\s*(.*?)\s*$') { $fields[$Matches[1]] = $Matches[2].Trim('"') }
  }
  $fields
}
function Set-HostFields([string]$GitlabHost, [hashtable]$Fields) {
  if (-not (Test-Path $ConfigFile)) { Fail "glab's config is not at $ConfigFile" }
  $raw = [IO.File]::ReadAllText($ConfigFile)
  $nl = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.AddRange([string[]]($raw -split "`r?`n"))
  $hosts = -1; $start = -1; $end = -1
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^hosts:\s*$') { $hosts = $i; continue }
    if ($hosts -ge 0 -and $start -lt 0 -and $lines[$i] -match ('^ {4}' + [regex]::Escape($GitlabHost) + ':\s*$')) { $start = $i; continue }
    if ($start -ge 0 -and ($lines[$i] -match '^ {4}\S' -or $lines[$i] -match '^\S')) { $end = $i; break }
  }
  if ($start -lt 0) { Fail "glab's config has no host ${GitlabHost}: log in once with glab auth login" }
  if ($end -lt 0) { $end = $lines.Count }
  foreach ($key in $Fields.Keys) {
    $value = [string]$Fields[$key]
    $text = if ($key -eq 'user' -or $value -eq '') { "        ${key}: $value".TrimEnd() } else { "        ${key}: `"$value`"" }
    $found = $false
    for ($i = $start + 1; $i -lt $end; $i++) { if ($lines[$i] -match ('^ {8}' + $key + ':')) { $lines[$i] = $text; $found = $true; break } }
    if (-not $found) {
      $at = $end; while ($at - 1 -gt $start -and $lines[$at - 1].Trim() -eq '') { $at-- }
      $lines.Insert($at, $text); $end++
    }
  }
  $tmp = "$ConfigFile.glab-accounts.tmp"
  [IO.File]::WriteAllText($tmp, ($lines -join $nl), (New-Object System.Text.UTF8Encoding $false))
  Move-Item -Force $tmp $ConfigFile
}

# ---- a login: what glab uses now, and putting one in place ---------------------------------------------------------------------------
function Get-Live([string]$GitlabHost) {
  $token = [GlabCred]::Read((Target $GitlabHost 'token'))
  if (-not $token) { return $null }
  $f = Get-HostFields $GitlabHost
  @{ host = $GitlabHost; username = [string]$f['user']; oauth = ($f['is_oauth2'] -eq 'true'); expiry = [string]$f['oauth2_expiry_date']
     token = $token; refresh = [string]([GlabCred]::Read((Target $GitlabHost 'oauth2_refresh_token'))) }
}
function Set-Live($State) {
  [GlabCred]::Write((Target $State.host 'token'), $State.token)
  if ($State.refresh) { [GlabCred]::Write((Target $State.host 'oauth2_refresh_token'), $State.refresh) }
  else { [GlabCred]::Delete((Target $State.host 'oauth2_refresh_token')) }
  Set-HostFields $State.host @{ user = $State.username; is_oauth2 = $(if ($State.oauth) { 'true' } else { 'false' }); oauth2_expiry_date = $State.expiry; use_keyring = 'true' }
}
# Asks GitLab, through glab (which renews an expired OAuth token by itself), who is logged in. '' when it fails.
function Ask-Who([string]$GitlabHost) {
  if ($NoVerify) { return (Get-HostFields $GitlabHost)['user'] }
  $out = & $Real api user --hostname $GitlabHost 2>$null | Out-String
  if ($LASTEXITCODE -ne 0) { return '' }
  try { ($out | ConvertFrom-Json).username } catch { '' }
}

# ---- the saved accounts -------------------------------------------------------------------------------------------------------------
function Protect([string]$Secret) { if (-not $Secret) { return '' }; ConvertTo-SecureString $Secret -AsPlainText -Force | ConvertFrom-SecureString }
function Unprotect([string]$Blob) {
  if (-not $Blob) { return '' }
  $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR((ConvertTo-SecureString $Blob))
  try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}
function Check-Name([string]$Name) {
  if (-not $Name) { Fail 'an account name is needed' }
  if ($Name -notmatch '^[A-Za-z0-9._-]{1,40}$') { Fail "« $Name » is not a valid account name (letters, digits, . - and _)" }
}
function Record-Path([string]$Name) { Join-Path $Store "$Name.json" }
function Get-Records { @(if (Test-Path $Store) { Get-ChildItem -Path $Store -Filter '*.json' | Sort-Object Name | ForEach-Object { Get-Content -Raw -Encoding UTF8 $_.FullName | ConvertFrom-Json } }) }
function Get-Record([string]$Name) {
  Check-Name $Name
  if (-not (Test-Path (Record-Path $Name))) { Fail "no account « $Name » (glab list)" }
  Get-Content -Raw -Encoding UTF8 (Record-Path $Name) | ConvertFrom-Json
}
function Save-Record([string]$Name, $State) {
  New-Item -ItemType Directory -Force -Path $Store | Out-Null
  [ordered]@{ name = $Name; host = $State.host; username = $State.username; oauth = $State.oauth; expiry = $State.expiry
    token = (Protect $State.token); refresh = (Protect $State.refresh); saved = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } |
    ConvertTo-Json | Set-Content -Encoding UTF8 (Record-Path $Name)
}
function State-Of($Record) {
  @{ host = $Record.host; username = $Record.username; oauth = [bool]$Record.oauth; expiry = [string]$Record.expiry
     token = (Unprotect $Record.token); refresh = (Unprotect $Record.refresh) }
}
function Safe-Name([string]$Username) { $n = ($Username -replace '[^A-Za-z0-9._-]', '-'); if ($n.Length -gt 40) { $n = $n.Substring(0, 40) }; $n }

# Saves the login glab uses now into its account (the one with that username on that host; a new one named after the username if none).
# Returns that account's name, or '' when glab has no login there.
function Stash-Live([string]$GitlabHost) {
  $live = Get-Live $GitlabHost
  if (-not $live -or -not $live.username) { return '' }
  $match = @(Get-Records | Where-Object { $_.host -eq $GitlabHost -and $_.username -eq $live.username })
  if ($match.Count -gt 0) { $name = $match[0].name }
  else {
    $name = Safe-Name $live.username
    if (Test-Path (Record-Path $name)) { $name = Safe-Name "$($live.username)-$GitlabHost" }
    Say "(glab was logged in as $($live.username): saved as « $name », come back with: glab use $name)"
  }
  Save-Record $name $live
  $name
}

# Options: --host <host>.
function Parse([string[]]$Arguments) {
  $o = @{ host = 'gitlab.com'; names = @(); force = $false }
  for ($i = 0; $i -lt $Arguments.Count; $i++) {
    switch ($Arguments[$i]) {
      '--host' { $i++; if ($i -ge $Arguments.Count) { Fail '--host needs a value' }; $o.host = $Arguments[$i] }
      default { $o.names += $Arguments[$i] }
    }
  }
  if ($o.host -notmatch '^[A-Za-z0-9.-]+(:[0-9]+)?$') { Fail "« $($o.host) » is not a host name" }
  $o
}

switch ($Command) {
  'add' {
    $o = Parse $Rest
    if ($o.names.Count -ne 1) { Fail 'usage: glab add <name> [--host gitlab.example.com]' }
    $name = $o.names[0]; Check-Name $name
    $existing = if (Test-Path (Record-Path $name)) { Get-Record $name } else { $null }
    $before = Get-Live $o.host
    $stashed = Stash-Live $o.host
    $again = $existing -and $before -and $existing.username -eq $before.username
    if ($before -and -not $again) { Say "Opening $($o.host) in your browser. Sign in there as the account to save as « $name »: if the browser is signed in as $($before.username), sign out of GitLab in the browser first." }
    else { Say "Opening $($o.host) in your browser to log in as « $name »." }
    & $Real auth login --hostname $o.host --web --git-protocol ssh
    $code = $LASTEXITCODE
    $after = Get-Live $o.host
    $restore = { if ($before) { Set-Live $before; Say "glab is back on $($before.username)." } }
    if ($code -ne 0 -or -not $after) { & $restore; Fail "the GitLab login did not finish (exit $code): nothing was added" }
    if (-not $after.username) { $after.username = Ask-Who $o.host }
    $other = @(Get-Records | Where-Object { $_.host -eq $o.host -and $_.username -eq $after.username -and $_.name -ne $name })
    if ($other.Count -gt 0) {
      & $restore
      Fail "you authorized $($after.username) again (already saved as « $($other[0].name) »). In the browser, sign out of GitLab or sign in as the other account, then: glab add $name"
    }
    if ($existing -and $existing.username -ne $after.username) {
      & $restore
      Fail "« $name » is $($existing.username), but the browser authorized $($after.username): nothing was changed (another name, or glab remove $name first)"
    }
    Save-Record $name $after
    Say "added « $name »: $($after.username) on $($o.host). glab now uses it$(if ($stashed -and $stashed -ne $name) { "; back with: glab use $stashed" })."
  }
  'use' {
    $o = Parse $Rest
    if ($o.names.Count -ne 1) { Fail 'usage: glab use <name>' }
    $record = Get-Record $o.names[0]
    $gitlabHost = $record.host
    $before = Get-Live $gitlabHost
    if ($before -and $before.username -eq $record.username) { [void](Stash-Live $gitlabHost); Say "glab already uses « $($record.name) »: $($record.username) on $gitlabHost"; break }
    [void](Stash-Live $gitlabHost)
    Set-Live (State-Of $record)
    $who = Ask-Who $gitlabHost
    if ($who -ne $record.username) {
      if ($before) { Set-Live $before }
      Fail "GitLab did not accept the saved login of « $($record.name) »$(if ($who) { " (it answered $who)" }) — revoked or expired. glab is back on $(if ($before) { $before.username } else { 'nothing' }). Log in again with: glab add $($record.name)"
    }
    Save-Record $record.name (Get-Live $gitlabHost)   # glab may have renewed the token while checking
    Say "glab now uses « $($record.name) »: $($record.username) on $gitlabHost"
  }
  { $_ -in 'list', 'ls' } {
    $records = Get-Records
    if ($records.Count -eq 0) { Say 'no saved account yet: glab add <name>'; break }
    $live = @{}
    foreach ($h in @($records | ForEach-Object { $_.host } | Sort-Object -Unique)) { $live[$h] = (Get-HostFields $h)['user'] }
    foreach ($r in $records) {
      $mark = if ($live[$r.host] -eq $r.username) { '*' } else { ' ' }
      $kind = if ($r.oauth) { 'browser login' } else { 'token' }
      Say ('{0} {1,-18} {2,-24} {3,-16} {4}' -f $mark, $r.name, $r.username, $r.host, $kind)
    }
  }
  { $_ -in 'remove', 'rm' } {
    $o = Parse $Rest
    if ($o.names.Count -ne 1) { Fail 'usage: glab remove <name>' }
    $record = Get-Record $o.names[0]
    if ((Get-HostFields $record.host)['user'] -eq $record.username) { Fail "« $($record.name) » is the account glab uses now: glab use <another> first" }
    Remove-Item -Force (Record-Path $record.name)
    Say "removed « $($record.name) » ($($record.username)). Its authorization stays on GitLab: revoke it there if you want (User settings > Applications)."
  }
  default {
    Say @'
glab accounts:
  glab add <name> [--host H]   log in with the browser (like glab auth login) and save that account as <name>
  glab list                    the saved accounts (* = the one glab uses now)
  glab use <name>              switch glab to that account (everywhere, until the next use)
  glab remove <name>           forget a saved account (not the one in use)
Every other command is glab itself.
'@
  }
}
