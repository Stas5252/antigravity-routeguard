# RouteGuard layer model

This document records the failure layers RouteGuard is designed around. The important point is that Antigravity does **not** have one single "region check"; different clients and transports can fail at different stages.

## 1. IDE/UI sign-in gate

Known IDE builds include a local branch around `isGoogleInternal`. Open AG Patcher handles this by changing the branch input after `resetIsTierGCPTos()` to `true`.

RouteGuard 0.3 mirrors the same idea with a narrow regex against the known Antigravity `main.js` pattern and backs up the file before changing it.

Purpose: remove a **client-side** sign-in/region gate.

Not sufficient for: a server returning HTTP 400 after the model request actually reaches CloudCode.

## 2. Language-server / account eligibility payload

Current confeden/Antigravity builds use a same-length binary-string rewrite:

```text
ineligible -> inexigible
```

This changes the protobuf field name the client gates on without changing binary size or offsets. The same substring also changes `ineligible_tiers` consistently.

RouteGuard applies this only when the stock signature is present, stores a per-file backup + original/patched SHA-256, and re-applies after an Antigravity update.

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

Known gate-host AAAA queries receive NOERROR/NODATA, so the gate cannot escape over native IPv6.

## 6. QUIC / UDP / IPv6

For the injected Antigravity processes RouteGuard configures:

```text
udp_mode      = block
udp_fallback  = block
ipv6_mode     = block
default route = proxy
```

The aim is fail-closed behaviour: a broken proxy should cause a failed request, not a request from a different public IP.

## 7. Upstream proxy identity

A supported country is not enough by itself. Public Antigravity reports show the same account succeeding on one egress and failing on another, including differences between hosting/datacenter IPs.

RouteGuard checks the upstream egress three times before Setup/Repair and refuses a changing/rotating egress. Use a sticky/static proxy for agent work.

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

RouteGuard's watchdog checks every five minutes and re-applies known signatures. Unknown signatures are not guessed.

The RouteGuard release itself is rebuilt in GitHub Actions. The updater downloads the ZIP plus `SHA256SUMS.txt` and verifies the archive before replacing local RouteGuard files.

## 10. Rollback

RouteGuard stores backups for eligibility-patched files with:

- target path
- original SHA-256
- patched SHA-256
- backup path

Restore only writes a backup when the current file still has the exact patched hash. If Antigravity updated the file meanwhile, the stale backup is skipped rather than downgrading the application.

NRPT rules created by RouteGuard are tagged with the RouteGuard comment and Restore removes only those rules.
