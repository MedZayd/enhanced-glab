# Stands in for glab.exe in the tests (GLAB_REAL): `auth login` logs in as $env:STUB_LOGIN_USER (or fails when it is « fail »), like glab:
# a token and a refresh token in the credential store, user / is_oauth2 / oauth2_expiry_date in config.yml. `api user` answers the
# config's user (or fails when STUB_API_FAIL=1). Runs inside glab-accounts.ps1, so it uses its GlabCred class and Set-HostFields.
$h = $null; for ($i = 0; $i -lt $args.Count; $i++) { if ($args[$i] -eq '--hostname') { $h = $args[$i + 1] } }
if ($args[0] -eq 'auth' -and $args[1] -eq 'login') {
  if ($env:STUB_LOGIN_USER -eq 'fail') { $global:LASTEXITCODE = 1; return }
  $u = $env:STUB_LOGIN_USER
  [GlabCred]::Write("glab:${h}:token:", "tok-$u-1"); [GlabCred]::Write("glab:${h}:oauth2_refresh_token:", "ref-$u-1")
  Set-HostFields $h @{ user = $u; is_oauth2 = 'true'; oauth2_expiry_date = '2030-01-01T00:00:00Z' }
  $global:LASTEXITCODE = 0; return
}
if ($args[0] -eq 'api' -and $args[1] -eq 'user') {
  if ($env:STUB_API_FAIL -eq '1') { $global:LASTEXITCODE = 1; return }
  Write-Output ('{"username":"' + (Get-HostFields $h)['user'] + '"}'); $global:LASTEXITCODE = 0; return
}
$global:LASTEXITCODE = 2
