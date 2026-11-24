#!/bin/bash
# enhanced-glab against a FAKE host (fake-test.invalid), a throwaway glab config and account folder, and stub-glab.ps1 in place
# of glab.exe: no browser, no GitLab, and the real gitlab.com login is never read or written.
set -u
here="$(cd "$(dirname "$0")" && pwd)"; repo="$(cd "$here/.." && pwd)"; T="$(mktemp -d)"
export GLAB_CONFIG_DIR="$(cygpath -w "$T/cfg")" GLAB_ACCOUNTS_DIR="$(cygpath -w "$T/accounts")" GLAB_REAL="$(cygpath -w "$here/stub-glab.ps1")"
mkdir -p "$T/cfg"
printf '%s\r\n' '# a config like glab'"'"'s' 'git_protocol: ssh' 'hosts:' '    fake-test.invalid:' '        api_protocol: https' '        user: alice' '        use_keyring: "true"' '        git_protocol: ssh' '        is_oauth2: "true"' '        oauth2_expiry_date: "2029-01-01T00:00:00Z"' '    other.invalid:' '        user: zed' 'telemetry: false' > "$T/cfg/config.yml"
cp "$T/cfg/config.yml" "$T/config.orig"
glab() { "$repo/glab" "$@"; }   # this repo's launcher, not an installed one
G() { glab "$@" --host fake-test.invalid; echo "   exit=$?"; }
peek() { powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$here/peek.ps1")" "$@"; }
seed() { powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Add-Type -TypeDefinition (Get-Content -Raw '$(cygpath -w "$repo/glab-accounts.ps1")' | Select-String -Pattern '(?s)@\"(.*?)\"@').Matches[0].Groups[1].Value; [GlabCred]::Write('glab:fake-test.invalid:token:','tok-alice-1'); [GlabCred]::Write('glab:fake-test.invalid:oauth2_refresh_token:','ref-alice-1')"; }

echo "== 0. help and an empty list"; glab add; echo "   exit=$?"; glab list
echo "== 1. glab is logged in as alice (seeded)"; seed; peek
echo "== 2. add bob, but the browser login fails -> alice saved, glab back on alice, nothing added"
STUB_LOGIN_USER=fail G add bob; peek; glab list
echo "== 3. add bob (browser signed in as bob)"; STUB_LOGIN_USER=bob G add bob; peek; glab list
echo "== 4. glab renews bob's tokens by itself (tok-bob-2 / ref-bob-2), then: use alice"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Add-Type -TypeDefinition (Get-Content -Raw '$(cygpath -w "$repo/glab-accounts.ps1")' | Select-String -Pattern '(?s)@\"(.*?)\"@').Matches[0].Groups[1].Value; [GlabCred]::Write('glab:fake-test.invalid:token:','tok-bob-2'); [GlabCred]::Write('glab:fake-test.invalid:oauth2_refresh_token:','ref-bob-2')"
glab use alice; echo "   exit=$?"; peek; glab list
echo "== 5. use bob: must come back with the RENEWED tokens (tok-bob-2 / ref-bob-2)"; glab use bob; echo "   exit=$?"; peek
echo "== 6. use bob again"; glab use bob; echo "   exit=$?"
echo "== 7. add carol, but the browser is still signed in as alice -> refused, glab back on bob"; STUB_LOGIN_USER=alice G add carol; peek; glab list
echo "== 8. add bob again with bob (log in again) -> allowed"; STUB_LOGIN_USER=bob G add bob; peek
echo "== 9. add bob with carol -> refused (bob is bob), glab back on bob"; STUB_LOGIN_USER=carol G add bob; peek
echo "== 10. use alice, GitLab refuses alice's saved login -> glab back on bob"; STUB_API_FAIL=1 glab use alice; echo "   exit=$?"; peek
echo "== 11. remove the one in use -> refused; remove alice -> ok"; glab remove bob; echo "   exit=$?"; glab remove alice; echo "   exit=$?"; glab list
echo "== 12. wrong input"; glab use; glab use nobody; glab add "../x"; glab remove; glab add x --host "bad host"
echo "== 13. the account files: no secret in clear"; grep -l -E "tok-|ref-" "$T/accounts"/*.json && echo "   SECRET FOUND" || echo "   no tok-/ref- value in any account file"
echo "== 14. config.yml: other lines kept, CRLF kept"; diff <(tr -d '\r' < "$T/config.orig") <(tr -d '\r' < "$T/cfg/config.yml"); echo "   CR lines: $(grep -c $'\r' "$T/cfg/config.yml") of $(wc -l < "$T/cfg/config.yml")"
peek clean; rm -rf "$T"
