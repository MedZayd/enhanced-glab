# enhanced-glab

Several GitLab accounts in [glab](https://gitlab.com/gitlab-org/cli) on Windows, with glab's own browser login, and switching between them:

```powershell
glab add work         # opens GitLab in the browser, like `glab auth login`, and saves that account as « work »
glab add personal     # same, for another account (sign the browser in as that account first)
glab list             # the saved accounts, * = the one glab uses now
glab use personal     # glab now uses « personal »: in PowerShell, cmd, Git Bash, scripts, until the next `use`
glab remove work      # forget a saved account (not the one in use)
```

```text
> glab list
* work               jane.doe            gitlab.com       browser login
  personal           janedoe             gitlab.com       browser login
```

Every other command (`glab mr list`, `glab ci status`, …) is passed to the real glab unchanged.

## Why

glab keeps **one login per host**. If you have a work account and a personal account on `gitlab.com`, you have to log out and in
again (in the browser) every time you change. GitHub's `gh` has `gh auth switch`; glab doesn't (yet).

## How it works

- `glab.cmd` (PowerShell, cmd) and `glab` (Git Bash) sit in a folder **before** the real glab on `PATH`. They send `add`, `list`, `use`
  and `remove` to `glab-accounts.ps1`, and every other command straight to the real `glab.exe` (found on `PATH`, or `GLAB_REAL`).
- glab stores a login in the Windows Credential Manager (`glab:<host>:token:` and `glab:<host>:oauth2_refresh_token:`) plus three lines
  of its `config.yml` (`user`, `is_oauth2`, `oauth2_expiry_date`). A saved account is a copy of those, the two secrets encrypted with
  **DPAPI** for your Windows user, in `%APPDATA%\glab-accounts\<name>.json`. Nothing is ever printed or stored in clear.
- `glab use` first saves the login in use (glab renews its OAuth tokens about every 2 hours, so the copy is taken when you leave an
  account), puts the chosen one in place and asks GitLab who it is. If GitLab refuses it (revoked, expired), the previous login is put back.
- `glab add` saves the login in use, runs `glab auth login --web`, and refuses (putting the previous login back) if the browser authorized
  an account that is already saved under another name: sign the browser out of GitLab, or into the other account, first.
- Works with any GitLab host: `glab add <name> --host gitlab.example.com`. Personal-access-token logins are saved and switched too.

## Install

Requires Windows, glab (`winget install GLab.GLab`) and Windows PowerShell 5.1 (built in).

```powershell
git clone https://github.com/MedZayd/enhanced-glab
cd enhanced-glab
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1     # copies into %USERPROFILE%\.local\bin (or -Dir <folder>)
```

The folder must be on `PATH` **before** glab's own folder; the installer checks and tells you. To uninstall, delete the three files
(and `%APPDATA%\glab-accounts`).

## Tests

```bash
bash tests/run-tests.sh
```

They run against a fake host (`fake-test.invalid`) with a throwaway glab config and account folder, and a stub in place of glab
(`tests/stub-glab.ps1`): no browser opens, no network, and your real glab login is never read or written. They cover a failed browser
login, a login as an already-saved account, switching back with tokens glab renewed in the meantime, a saved login GitLab refuses,
removing, bad input, no secret in clear, and `config.yml` keeping its other lines and line endings.

## Limits

- Windows only (Credential Manager, DPAPI).
- It relies on how glab 1.x stores its login (credential names and `config.yml` keys); tested with glab 1.118.
- `glab use` switches glab for every terminal at once (it changes glab's own login), not per terminal.

## Licence

MIT, see [LICENSE](LICENSE).
