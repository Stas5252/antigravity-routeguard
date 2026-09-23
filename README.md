# AG RouteGuard

AG RouteGuard is a Windows-only Antigravity network patcher focused on one job: **keep Antigravity model traffic on one known SOCKS5 egress, including authenticated SOCKS5 proxies, and automatically repair the hook after Antigravity updates.**

## Why this exists

A recurring Antigravity failure is:

```text
HTTP 400 Bad Request
User location is not supported for the API use.
```

The difficult part is that the browser/UI can use one route while `language_server`, `node.exe`, CLI/agent execution, or a child process opens another socket path. RouteGuard uses a per-process Winsock hook plus a local SOCKS5 bridge:

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

## Current features

- auto-detects the Antigravity Windows install;
- injects `Antigravity.exe`, `Antigravity IDE.exe`, `language_server*`, `node.exe`, and `agy.exe`;
- routes TCP 80/443 through one local SOCKS5 bridge;
- blocks UDP/QUIC fallback and native IPv6 in target processes to reduce direct egress leaks;
- supports authenticated SOCKS5 upstream proxies;
- stores the upstream password using Windows DPAPI for the current Windows user;
- verifies the real proxy egress IP before patching;
- keeps backups and supports Restore;
- starts the bridge at Windows logon;
- runs a watchdog every 5 minutes: if an Antigravity update removes/replaces the hook, RouteGuard restores it automatically;
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
5. Run:

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

`Status` verifies the upstream egress and checks the newest Antigravity agent log for the location-400 message.

## Auto-repair

Setup creates two per-user scheduled tasks:

- **AG RouteGuard Bridge** — starts the local bridge at logon;
- **AG RouteGuard Watchdog** — every 5 minutes verifies that the bridge is alive and that Antigravity still has RouteGuard's `version.dll` and generated `config.json`. If an Antigravity update replaces them, the watchdog re-applies the hook for the next Antigravity launch.

## Security choices

- no proxy credentials are hardcoded in the repository or release;
- upstream password is DPAPI-protected for the current Windows account;
- the network injector is built from a **pinned source commit** in CI rather than downloading an opaque DLL at runtime;
- releases contain SHA-256 checksums and the built-in updater verifies them;
- no TLS interception, certificate installation, or HTTPS decryption;
- Restore preserves files that existed before RouteGuard installation;
- external routing fails closed for UDP/IPv6 rather than silently falling back to a different public egress.

## Upstream

The per-process network hook is built from `yuaotian/antigravity-proxy` at pinned commit:

```text
32785d2098c9a07c6b7060f47d04a17ac0e5a431
```

See `THIRD_PARTY_NOTICES.md`.
