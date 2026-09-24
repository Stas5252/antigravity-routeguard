# Changelog

## 0.5.0 — 2026-09-24

### Reliability
- Stable authenticated SOCKS5 bridge with retries and long-stream TCP tuning.
- Three-pass preflight egress verification plus runtime egress pinning/fail-closed behavior.
- Separate Google/CloudCode TLS probes before setup accepts a proxy.
- Deterministic `Launch.cmd` process environment for the private language-server proxy channel.
- Optional one-launch production CloudCode fallback via `LaunchProduction.cmd`.
- Exact CloudCode gate fallback using tagged Windows NRPT rules, local DNS, loopback TLS doors, and no TLS interception.
- Fail-closed UDP/QUIC and IPv6 policy for injected Antigravity processes.

### Eligibility / compatibility
- Reversible client-side eligibility patches for known Antigravity IDE, language-server and CLI signatures.
- Private `AG_LS_PROXY` channel instead of changing global `HTTPS_PROXY`.
- Unknown binary signatures are reported and left untouched.
- Detection of legacy/conflicting Antigravity patchers, proxy variables, CloudCode overrides and hosts-file rules.

### Updates and rollback
- Watchdog defers repairs while Antigravity is running so an active agent task is not killed.
- Verified rolling self-update with outer SHA-256 plus per-file `MANIFEST.sha256`.
- Release packages are stamped with the immutable Git commit.
- Hash-tracked backups avoid restoring stale files over a newer Antigravity update.
- Persistent helper commands are updated together with the installed core.

### Security / diagnostics
- Proxy password is stored with Windows DPAPI and removed from the bridge process environment after startup.
- Sanitized `Report.cmd` output does not include the stored proxy password or raw conversations.
- CI runs Go tests/vet, PowerShell 7 parsing/tests, Windows PowerShell 5.1 parsing/tests, and release-version consistency checks.

### Limitation
RouteGuard can patch known local eligibility gates and make the client network route deterministic. It cannot rewrite Google's server-side account country, entitlement, quota, IP/ASN reputation, or backend eligibility decision.
