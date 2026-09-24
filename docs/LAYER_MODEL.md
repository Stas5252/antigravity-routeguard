# RouteGuard layer model

This document records the failure layers RouteGuard is designed around. The important point is that Antigravity does **not** have one single "region check"; different clients and transports can fail at different stages.

## 1. IDE/UI sign-in gate

Known IDE builds include a local branch around `isGoogleInternal`. Open AG Patcher handles this by changing the branch input after `resetIsTierGCPTos()` to `true`.

RouteGuard 0.6 mirrors the same idea with a narrow regex against the known Antigravity `main.js` pattern and backs up the file before changing it.

Purpose: remove a **client-side** sign-in/region gate.

Not sufficient for: a server returning HTTP 400 after the model request actually reaches CloudCode.

## 2. Language-server / account eligibility payload

Current confeden/Antigravity builds use a same-length binary-string rewrite:

```text
ineligible -> inexigible
```

This changes the protobuf field name the client gates on without changing binary size or offsets. The same substring also changes `ineligible_tiers` consistently.

RouteGuard applies the same-length field rewrite when present and separately recognizes the current Windows x64 CLI/manager machine-code gates. Known machine signatures are patched without guessed offsets; unknown layouts are reported rather than modified. Per-file backups keep original/patched SHA-256 values and survive additional RouteGuard patches on the same Antigravity build.

Purpose: remove the local/client interpretation of an account eligibility field.

Not sufficient for: changing the actual Google Account country stored on Google's servers.

## 3. CloudCode endpoint

Antigravity surfaces have used both:

- `cloudcode-pa.googleapis.com`
- `daily-cloudcode-pa.googleapis.com`

Different releases/accounts may choose different endpoints. RouteGuard does **not** force one endpoint globally. Instead it routes both through the same egress.

This avoids relying on a single endpoint override that may become stale after an app update.

## 4. Model transport bypassing ordinary proxy settings

There are public Antigravity reports where OAuth / eligibility HTTP respects `HTTPS_PROXY` while the actual model-call transport does not.

RouteGuard therefore does not rely on `HTTPS_PROXY` alone.

Primary path:

```text
Antigravity.exe / language_server* / node.exe / agy.exe
            -> per-process Winsock hook
            -> 127.0.0.1:17890
            -> authenticated upstream SOCKS5
```

The hook is built from a pinned source commit of `yuaotian/antigravity-proxy`.

## 5. Gate-host DNS fallback

A second independent path is installed for the two CloudCode hosts.

Windows NRPT sends only those two names to a tiny RouteGuard DNS listener:

```text
cloudcode-pa.googleapis.com       -> 127.65.71.1
daily-cloudcode-pa.googleapis.com -> 127.65.71.2
DNS server                         -> 127.0.0.53
```

RouteGuard listens on both loopback addresses at TCP/443. It does not terminate TLS. It simply opens a tunnel to the original hostname through the configured upstream SOCKS5 and splices bytes.

Why this exists: even a transport that ignores the ordinary proxy setting still resolves the gate hostname to RouteGuard and cannot silently escape to the ISP.

This is a **fallback layer**, not a prerequisite for the primary process-proxy path. If the local DNS/443 listener cannot be bound because another VPN or service owns the port, RouteGuard removes its own NRPT rules and continues with `AG_LS_PROXY` + the Winsock hook rather than leaving a dead DNS policy installed.

Known gate-host AAAA queries receive NOERROR/NODATA, so the gate cannot escape over native IPv6. RouteGuard flushes the Windows DNS cache after adding/removing these exact-gate rules so a previously cached real Google address does not survive the transition.

## 6. QUIC / UDP / IPv6

For the injected Antigravity processes RouteGuard configures:

```text
dns_mode      = direct
udp_mode      = block
udp_fallback  = block
ipv6_mode     = block
default route = proxy
```

The ordinary DNS setting is deliberately `direct`: the pinned injector's port allowlist is HTTP/HTTPS (80/443), and its own documentation recommends direct DNS to avoid DNS timeouts. Google application connections still use the proxy path, and the two location-sensitive CloudCode gate names retain the independent NRPT + loopback-tunnel fallback. This trades DNS-query privacy for application stability without allowing model HTTPS to fall back to the ISP.

The aim is fail-closed behaviour: a broken proxy should cause a failed request, not a request from a different public IP. This is intentionally stricter than compatibility-first routing. Some newer Electron/Chromium flows prefer QUIC and may not always fall back cleanly; RouteGuard does **not** silently allow direct UDP because doing so would re-introduce an egress leak.

## 7. Upstream proxy identity

A supported country is not enough by itself. Public Antigravity reports show the same account succeeding on one egress and failing on another, including differences between hosting/datacenter IPs.

RouteGuard checks the upstream egress three times before Setup/Repair and refuses a changing/rotating egress. The bridge also pins the observed IP during runtime: a changed IP, or three consecutive inability-to-verify events, blocks new proxied connections until the expected IP is seen again. Existing streams are not deliberately killed. Use a sticky/static proxy for agent work.

A stable route still cannot guarantee that Google accepts a particular ASN or IP reputation.

## 8. Google Account country

Google's official Antigravity FAQ says geographical availability also depends on the country associated with the Google Terms of Service page.

RouteGuard can remove known **local** eligibility gates and can make the network egress deterministic. It does not and should not claim to rewrite Google's server-side account record.

Therefore these are separate states:

```text
local eligibility patch = green
network egress           = green
CloudCode gate route     = green
Google backend policy    = still authoritative
```

If the first three are proven and Google still returns the same location/eligibility error, the remaining decision is server-side.

## 9. Updates

Antigravity updates can replace:

- `version.dll` neighbours / install files
- `language_server*.exe`
- `main.js`

RouteGuard's watchdog checks every five minutes. It also checks the private `AG_LS_PROXY` value and known IDE/native eligibility state. If Antigravity is currently running, repair is queued rather than killing an active `language_server`; the repair is applied after Antigravity is closed. Unknown signatures are not guessed.

The RouteGuard release itself is rebuilt in GitHub Actions. The updater downloads the ZIP plus `SHA256SUMS.txt` and verifies the archive before replacing local RouteGuard files.

## 10. Rollback

RouteGuard stores backups for eligibility-patched files with:

- target path
- original SHA-256
- patched SHA-256
- backup path

Restore only writes a backup when the current file still has the exact patched hash. If Antigravity updated the file meanwhile, the stale backup is skipped rather than downgrading the application.

NRPT rules created by RouteGuard are tagged with the RouteGuard comment and Restore removes only those rules.


## 11. Deterministic launch

Windows user environment changes are persistent but a long-running shell such as Explorer may not immediately refresh its inherited environment. `Launch.cmd` starts Antigravity from RouteGuard's own process with:

```text
AG_LS_PROXY=http://127.0.0.1:17890
```

set explicitly for that process tree. This makes the first post-install test deterministic even if Explorer still has an old environment block. The DNS fallback and Winsock hook remain independent layers.

## 12. What a fully green RouteGuard result proves

A green local report proves that the known client gates are patched, the language-server/private proxy path is present, the configured SOCKS egress is stable, the Google/CloudCode TLS endpoints are reachable through it, and no known local conflict was found.

It does **not** prove that Google's backend will classify the account or proxy IP as eligible. A server-side `400 FAILED_PRECONDITION` can therefore remain after every local/network check is green; that state must be treated as a backend/account/IP-classification outcome rather than silently adding more local patches.


## 13. Default vs production CloudCode backend

Current public Antigravity CLI reports show a distinct failure mode where `daily-cloudcode-pa.googleapis.com` returns `400 FAILED_PRECONDITION` for Gemini while the same account/network sent to `cloudcode-pa.googleapis.com` no longer returns the location error (often exposing a separate quota/entitlement result instead). RouteGuard therefore keeps the normal backend as the default and provides `LaunchProduction.cmd` as an explicit one-launch diagnostic/fallback. It never auto-switches backends because that could change quota and entitlement behavior.
