# Changelog

## 7.0 — 2026-10-17 (first public release)

Everything below was found and fixed in production on a fleet of relay hubs.

* **Apply:** exact rule check via `iptables -C` instead of grep over `iptables -S` (the grep
  never matched the real rule text, so every run appended one more copy of each rule);
  every rule is now `-C || -A`.
* **Apply:** PREROUTING DNAT is guarded with `-m addrtype --dst-type LOCAL`, so transit UDP of
  other services on the box (IPsec/AWG rekeys to third parties on the same port) is never hijacked.
* **Apply:** `--replace` mode flushes every tagged rule and rebuilds from the config; stale rules
  on the same port with a different destination are dropped automatically.
* **Watchdog:** idle-aware stall detection. A mapping whose counter never moved is idle, not
  stalled; conntrack is flushed only when traffic that *was* flowing stops. Removes tens of
  thousands of false `STALL` log lines per day on quiet relays.
* **Kernel:** `nf_conntrack` is loaded before `systemd-sysctl` (`modules-load.d`), and a new
  `warp-relay-sysctl-reapply.service` re-applies the sysctl file after the network is up.
  Without this the 120/180 s UDP timeouts silently reverted to the kernel's 30 s on every reboot.
* **WARP preset:** relay `:4500` now targets `engage.cloudflareclient.com:2408` (WireGuard data
  port). The old `4500 → 4500` mapping never worked.
* **Backend:** the script no longer switches the iptables backend to legacy; it works on
  `iptables-nft` and coexists with nft-based tproxy/VPN rules.
* **Setup:** non-Debian systems get a warning instead of a crash in `apt-get`.
* `--version` / `--help`, shellcheck-clean, LF line endings enforced via `.gitattributes`.

## 6.0 — 2026-09 (internal)

Setup wizard + management TUI in one file, live dashboard, per-client traffic with geo lookup,
mapping editor, service control, diagnostics screen.

## 1.0–5.x — 2026-03..08 (internal)

Plain apply script + watchdog + systemd units.
