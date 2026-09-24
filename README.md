# AG RouteGuard

AG RouteGuard is a Windows-only Antigravity compatibility/unlock layer. Current release line: **0.6.0**. It handles **local eligibility checks, CloudCode gate routing, authenticated SOCKS5 egress, leak prevention, diagnostics, rollback, and auto-repair after Antigravity updates.**

## Why this exists

A recurring Antigravity failure is:

```text
HTTP 400 Bad Request
User location is not supported for the API use.
```

The difficult part is that there are several independent failure layers: IDE-side account/region checks, language-server eligibility fields, the CloudCode endpoint, model transports that can bypass ordinary proxy variables, IPv6/QUIC escapes, proxy IP/ASN reputation, and finally Google's own server-side account-country policy. RouteGuard therefore uses layered routing rather than one proxy toggle:

- known local eligibility gates are patched with reversible signatures;
- Antigravity processes are forced through a local SOCKS5 bridge;
- the two CloudCode gate hostnames also get a separate NRPT + loopback tunnel path, so a model transport that ignores ordinary proxy settings still cannot silently leave via the ISP.

Primary per-process path:

```text
Antigravity / language_server / node.exe / agy.exe
                    |
                    v
        version.dll per-process hook
                    |
                    v
        127.0.0.1:17890 (SOCKS5 no-auth)
                    |
                    v
              agbridge.exe
                    |
                    v
      authenticated upstream SOCKS5
                    |
                    v
              Google endpoints
```

The local bridge is needed because the pinned upstream injector negotiates SOCKS5 no-auth. RouteGuard adds RFC 1929 username/password authentication without putting proxy credentials in the repository.

For the gate fallback, Windows NRPT points only `cloudcode-pa.googleapis.com` and `daily-cloudcode-pa.googleapis.com` at RouteGuard's local DNS server (`127.0.0.53`). They resolve to separate loopback addresses where RouteGuard tunnels raw TLS through the same upstream proxy. TLS is not intercepted or decrypted.

## Current features

- auto-detects the Antigravity Windows install;
- injects `Antigravity.exe`, `Antigravity IDE.exe`, `language_server*`, `node.exe`, and `agy.exe`;
- routes TCP 80/443 through one local SOCKS5 bridge;
- blocks UDP/QUIC fallback and native IPv6 in target processes to reduce direct egress leaks; ordinary DNS uses the system resolver for compatibility, while the two CloudCode gate names retain the separate RouteGuard NRPT/tunnel fallback;
- supports authenticated SOCKS5 upstream proxies and retries transient upstream SOCKS connection/auth failures before failing a new agent request;
- stores the upstream password using Windows DPAPI for the current Windows user and removes proxy credentials from the long-running bridge process environment immediately after startup;
- verifies the real proxy egress three times before patching and rejects rotating/changing egress;
- verifies TLS connectivity through that same proxy to `oauth2.googleapis.com`, `cloudcode-pa.googleapis.com`, and `daily-cloudcode-pa.googleapis.com` before Setup/Repair;
- patches the known IDE `isGoogleInternal` local gate when its exact pattern is present and includes that IDE state in watchdog/post-install verification;
- patches the language-server/CLI eligibility field with the same-length `ineligible -> inexigible` rewrite used by current unlockers;
- installs tagged NRPT rules only for the two CloudCode gate hosts and answers their AAAA queries with NODATA to prevent an IPv6 escape;
- keeps backups and supports Restore;
- starts the bridge at Windows logon;
- runs a watchdog every 5 minutes: it checks the hook, config, native eligibility state, IDE local gate, and private `AG_LS_PROXY` channel; if an Antigravity update removes/replaces a known patch, RouteGuard marks a repair pending while Antigravity is running and applies it only after Antigravity is closed, so an active agent run is not killed;
- checks the rolling RouteGuard release periodically, verifies `SHA256SUMS.txt`, and auto-updates only while Antigravity is closed; otherwise the update is deferred safely;
- can self-update from GitHub Releases, verifies the outer ZIP with `SHA256SUMS.txt`, then verifies every packaged file against the inner `MANIFEST.sha256` before replacing installed files;
- stamps each release with its immutable Git commit so the updater can tell exactly which rolling build is installed;
- keeps `Launch.cmd`, `Accounts.cmd`, `Status.cmd`, `Report.cmd`, `Restore.cmd` and the other helpers in the persistent `%LOCALAPPDATA%\AGRouteGuard` install so auto-update updates the tools the user actually runs;
- integrates with Antigravity Tools' localhost account API for verified multi-account switching without reading or copying refresh tokens;
- validates the effective managed network policy on every watchdog/status pass and shows whether the newest Antigravity `ls-main.log` still contains the Google location-400 error;
- GitHub Actions builds the Windows x64 package from source and publishes SHA-256 checksums.

## Important limitation

RouteGuard can make the network path deterministic. It **cannot guarantee that Google's server-side account/eligibility policy will accept a particular Google account or egress IP**. If every agent/model socket is demonstrably proxied and Google's backend still rejects the account or IP, no local network patch can reliably override that server-side decision.

## Install

1. Download `AGRouteGuard-win-x64.zip` and `SHA256SUMS.txt` from the latest GitHub Release.
2. Verify the ZIP checksum.
3. Extract the ZIP.
4. Close Antigravity completely.
5. Double-click **`Install.cmd`**. It launches `AGRouteGuard.ps1 -Action Setup` and requests elevation only for the Windows DNS/NRPT part.

PowerShell equivalent:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\AGRouteGuard.ps1 -Action Setup
```

Enter your SOCKS5 host/IP, port, username, and password when prompted. The password is encrypted for the current Windows user with DPAPI and stored in:

```text
%LOCALAPPDATA%\AGRouteGuard\proxy.json
```

RouteGuard does not need Happ/TUN for the Antigravity path. Using a second VPN layer at the same time can add latency and another failure point, so test RouteGuard by itself first.

### Two-account / Antigravity Tools setup

RouteGuard 0.6 can use Antigravity Tools' local HTTP account API (default `127.0.0.1:19527`) to switch between accounts. Double-click `Accounts.cmd` or run `AGRouteGuard.ps1 -Action Accounts`.

Recommended Antigravity Tools network setup when using this feature:

```text
Proxy Pool: OFF
Global Upstream Proxy: ON
URL: socks5h://127.0.0.1:17890
```

That makes Antigravity Tools' own OAuth/token-refresh requests leave through the same authenticated RouteGuard egress instead of creating a second independent public route. The external proxy credentials remain only inside RouteGuard. Account switching can restart Antigravity, so do not switch in the middle of an agent task you need to preserve.

The account helper discovers a custom Antigravity Tools HTTP API port from its settings when available, lists the accounts, submits the official `/accounts/switch` request, and waits until `/accounts/current` confirms the requested account. It never reads account refresh tokens.

## Commands

```powershell
.\AGRouteGuard.ps1 -Action Status
.\AGRouteGuard.ps1 -Action Repair
.\AGRouteGuard.ps1 -Action Reconfigure
.\AGRouteGuard.ps1 -Action Update
.\AGRouteGuard.ps1 -Action Accounts
.\AGRouteGuard.ps1 -Action Restore
```

`Status` verifies the upstream egress, Google/CloudCode TLS path, local eligibility patch state, NRPT rules, gate-DNS answers, loopback TCP/443 listeners, live language-server sockets, injector logs, and the newest Antigravity agent log for location/eligibility/proxy errors. If the default daily backend still returns location 400 without an account-level 403, `LaunchProduction.cmd` is available as an explicit diagnostic/fallback that sets `CLOUD_CODE_URL=https://cloudcode-pa.googleapis.com` only for that launch. You can also double-click `Status.cmd`. `Report.cmd` writes a sanitized diagnostic report to the Desktop without copying the stored proxy password or raw conversation logs. `Launch.cmd` starts Antigravity from the RouteGuard process environment so the patched language server definitely inherits `AG_LS_PROXY`, even when Windows Explorer has not refreshed user environment variables yet.

For the full failure-layer model, see `docs/LAYER_MODEL.md`.

## Auto-repair

Setup creates two per-user scheduled tasks:

- **AG RouteGuard Bridge** — starts the local bridge at logon;
- **AG RouteGuard Watchdog** — every 5 minutes verifies that the bridge is alive and that Antigravity still has RouteGuard's network hook, generated config, and known eligibility signatures. If Antigravity is currently running, repair is deferred rather than killing its language server. When Antigravity is closed, the pending repair is applied. The same watchdog performs a lightweight update check roughly every 12 hours and safely stages/applies the verified rolling release only while Antigravity is closed. Unknown signatures are not guessed.

## Security choices

- no proxy credentials are hardcoded in the repository or release;
- upstream password is DPAPI-protected for the current Windows account;
- the network injector is built from a **pinned source commit** in CI rather than downloading an opaque DLL at runtime;
- releases contain SHA-256 checksums and the built-in updater verifies them;
- no TLS interception, certificate installation, or HTTPS decryption;
- Restore preserves files that existed before RouteGuard installation using hash-tracked managed-file metadata; if Antigravity replaced a file during an update, RouteGuard leaves the newer file untouched instead of restoring a stale backup;
- external routing fails closed for UDP/IPv6 rather than silently falling back to a different public egress.

## Upstream

The per-process network hook is built from `yuaotian/antigravity-proxy` at pinned commit:

```text
32785d2098c9a07c6b7060f47d04a17ac0e5a431
```

See `THIRD_PARTY_NOTICES.md`.


## Быстрый старт по-русски

1. Полностью закрой Antigravity.
2. Распакуй `AGRouteGuard-win-x64.zip`.
3. Запусти `Install.cmd`.
4. Введи адрес, порт, логин и пароль своего **статического SOCKS5**.
5. Установщик три раза проверит один и тот же выходной IP и отдельно проверит TLS до OAuth + двух CloudCode endpoint'ов.
6. Для первого запуска используй **`Launch.cmd`** — так `AG_LS_PROXY` гарантированно попадёт в новый процесс Antigravity и его language server.
7. Если используешь 2 аккаунта в Antigravity Tools, включи там `Global Upstream Proxy = socks5h://127.0.0.1:17890`, оставь `Proxy Pool` выключенным и переключай аккаунты через **`Accounts.cmd`**.
8. Отправь реальный запрос модели и затем открой `Status.cmd`.

Если Antigravity обновился во время работы, RouteGuard не будет убивать активную задачу ради перепатча: он поставит ремонт в очередь и применит его после закрытия Antigravity.

Если после зелёных проверок маршрута Google всё равно возвращает `User location is not supported for the API use`, это уже не означает утечку IP автоматически: остаётся серверная eligibility/account policy Google, которую локальный патчер физически не переписывает.

### Backend fallback

`Launch.cmd` explicitly clears any inherited `CLOUD_CODE_URL` and starts the normal/default Antigravity backend. `LaunchProduction.cmd` explicitly selects `https://cloudcode-pa.googleapis.com` for one launch. This is **not** enabled automatically: current Antigravity reports show that the daily backend can return a location 400 while the production endpoint returns a different result for the same account/network, but production can also return quota/entitlement errors. Keeping the switch explicit avoids silently changing quota/backend behavior.
