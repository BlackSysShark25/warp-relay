# Changelog

## 7.0 (2026-10-17), first public release

Everything below was found and fixed on a fleet of relay hubs before it got here.

* Apply: rules are checked with `iptables -C` instead of grep over `iptables -S`. The
  grep never matched the real rule text, so every run appended one more copy of each
  rule. Every rule is now "check, then add".
* Apply: the PREROUTING DNAT is limited to local addresses of the relay
  (`-m addrtype --dst-type LOCAL`). Transit UDP of other services on the same port
  (IPsec or AmneziaWG rekeys to third parties, for example) is no longer hijacked.
* Apply: `--replace` flushes every tagged rule and rebuilds from the config. A stale
  rule on the same port with a different destination is dropped automatically.
* Watchdog: a mapping whose counter never moved is idle, not stalled. Conntrack is
  flushed only when traffic that was flowing stops. This removes tens of thousands of
  false `STALL` lines per day on quiet relays.
* Kernel: `nf_conntrack` is loaded before `systemd-sysctl` (`modules-load.d`), and the
  new `warp-relay-sysctl-reapply.service` applies the sysctl file again once the
  network is up. Without this the 120/180 s UDP timeouts silently went back to the
  kernel's 30 s on every reboot.
* WARP preset: relay `:4500` now targets `engage.cloudflareclient.com:2408`, the
  WireGuard data port. The old `4500 -> 4500` mapping never worked.
* Backend: the script no longer switches iptables to legacy. It works on `iptables-nft`
  and next to nft-based tproxy and VPN rules.
* `relay --update` and `relay --check-update`: self-update from GitHub with a syntax
  check before anything is replaced; the console has the same action under Services.
* Setup: a non-Debian system gets a warning instead of a crash in `apt-get`.
* `--version` and `--help`; shellcheck-clean; LF line endings enforced through
  `.gitattributes`.

## 6.0 (2026-09), internal

Setup wizard and management console in one file: live dashboard, per-client traffic
with geo lookup, mapping editor, service control, diagnostics screen.

## 1.0 to 5.x (2026-03 to 2026-08), internal

Plain apply script, watchdog and systemd units.
