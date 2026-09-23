# AG RouteGuard

AG RouteGuard is a Windows-only Antigravity compatibility/unlock layer. Current release line: **0.4.x**. It handles **local eligibility checks, CloudCode gate routing, authenticated SOCKS5 egress, leak prevention, diagnostics, rollback, and auto-repair after Antigravity updates.**

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
- blocks UDP/QUIC fallback and native IPv6 in target processes to reduce direct egress leaks;
- supports authenticated SOCKS5 upstream proxies and retries transient upstream SOCKS connection/auth failures before failing a new agent request;
- stores the upstream password using Windows DPAPI for the current Windows user;
- verifies the real proxy egress three times before patching and rejects rotating/changing egress;
- verifies TLS connectivity through that same proxy to `oauth2.googleapis.com`, `cloudcode-pa.googleapis.com`, and `daily-cloudcode-pa.googleapis.com` before Setup/Repair;
- patches the known IDE `isGoogleInternal` local gate when its exact pattern is present;
- patches the language-server/CLI eligibility field with the same-length `ineligible -> inexigible` rewrite used by current unlockers;
- installs tagged NRPT rules only for the two CloudCode gate hosts and answers their AAAA queries with NODATA to prevent an IPv6 escape;
- keeps backups and supports Restore;
- starts the bridge at Windows logon;
- runs a watchdog every 5 minutes: if an Antigravity update removes/replaces the hook, RouteGuard marks a repair pending while Antigravity is running and applies it only after Antigravity is closed, so an active agent run is not killed;
- checks the rolling RouteGuard release periodically, verifies `SHA256SUMS.txt`, and auto-updates only while Antigravity is closed; otherwise the update is deferred safely;
- can self-update from GitHub Releases and verifies the release ZIP against `SHA256SUMS.txt` before installing;
- shows whether the newest Antigravity `ls-main.log` still contains the Google location-400 error;
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

## Commands

```powershell
.\AGRouteGuard.ps1 -Action Status
.\AGRouteGuard.ps1 -Action Repair
.\AGRouteGuard.ps1 -Action Reconfigure
.\AGRouteGuard.ps1 -Action Update
.\AGRouteGuard.ps1 -Action Restore
```

`Status` verifies the upstream egress, Google/CloudCode TLS path, local eligibility patch state, NRPT rules, gate-DNS answers, loopback TCP/443 listeners, live language-server sockets, injector logs, and the newest Antigravity agent log for location/eligibility/proxy errors. You can also double-click `Status.cmd`. `Report.cmd` writes a sanitized diagnostic report to the Desktop without copying the stored proxy password or raw conversation logs.

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
6. После установки запусти Antigravity, отправь реальный запрос модели и затем открой `Status.cmd`.

Если Antigravity обновился во время работы, RouteGuard не будет убивать активную задачу ради перепатча: он поставит ремонт в очередь и применит его после закрытия Antigravity.

Если после зелёных проверок маршрута Google всё равно возвращает `User location is not supported for the API use`, это уже не означает утечку IP автоматически: остаётся серверная eligibility/account policy Google, которую локальный патчер физически не переписывает.
