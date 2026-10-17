# Warp Relay

**A UDP relay hub for VPN servers, done in the kernel.**
Clients connect to `relay-ip:port`; `iptables` DNAT + MASQUERADE forwards the stream to the
real VPN server abroad (WireGuard, AmneziaWG, Cloudflare WARP, Hysteria, any UDP). No userspace
proxy, no extra buffering, no CPU cost worth mentioning — and a watchdog that keeps the rules
and the kernel state honest after reboots, DNS changes and connection stalls.

[Русская версия ниже](#русская-версия).

```
                  :51820 ─────────► wg.example.com:51820
client ──► relay  :4500  ─────────► engage.cloudflareclient.com:2408 (Cloudflare WARP)
                  :40000 ─────────► 203.0.113.10:51821
```

## Why this and not `socat` / `gost` / `realm`

| | Warp Relay | userspace relays (`socat`, `gost`, `realm`) |
|---|---|---|
| data path | kernel netfilter (DNAT/MASQUERADE) | copy every packet through a process |
| latency / CPU | none added | measurable on small VPS |
| hostnames as targets | yes, re-resolved automatically | mostly yes |
| rules survive reboot | yes (`netfilter-persistent` + systemd) | depends on your unit files |
| watchdog | restores lost rules, flushes stuck conntrack, idle-aware | no |
| conntrack boot-order fix | yes (see below) | n/a |
| live TUI | per-mapping traffic, per-client traffic with geo/ISP | no |

Projects in the same niche: [arblark/cascad](https://github.com/arblark/cascad) (bash, DNAT for
TCP+UDP, IPv6, no watchdog), [zhboner/realm](https://github.com/zhboner/realm) and
[ginuerzh/gost](https://github.com/ginuerzh/gost) (userspace, far more features, more moving parts).

## Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/BlackSysShark25/warp-relay/main/install.sh)
```

or clone and run `sudo ./relay.sh`. The wizard installs dependencies, kernel settings, three
systemd units and the `relay` command. Afterwards:

```bash
sudo relay                    # management console (TUI)
sudo warp-relay-apply         # (re)apply rules from /etc/warp-relay/mappings.conf, idempotent
sudo warp-relay-apply --replace   # flush every relay rule and rebuild from the config
```

Tested on Debian 12/13 and Ubuntu 22.04/24.04, both `iptables-nft` and `iptables-legacy`
backends. The script never switches the backend: it coexists with your existing nft/tproxy rules.

## Config

`/etc/warp-relay/mappings.conf`, one mapping per line (see [`mappings.conf.example`](mappings.conf.example)):

```
# SRC_IP   SRC_PORT  DST_HOST_OR_IP               DST_PORT  LABEL
0.0.0.0    51820     wg.example.com               51820     wg-germany
0.0.0.0    4500      engage.cloudflareclient.com  2408      cloudflare-warp
0.0.0.0    40000     203.0.113.10                 51821     awg-finland
```

* `SRC_IP` is informational; the DNAT rule matches **any local address** of the relay
  (`-m addrtype --dst-type LOCAL`), so transit UDP traffic of your other services is never hijacked.
* `DST_HOST` may be a hostname. It is resolved on every apply and by the watchdog, so a VPN server
  that moves to a new IP only needs a DNS update.

## What the watchdog does (every 25 s)

1. **Rule recovery** — if a mapping has no DNAT rule (a firewall reload, `ufw`, a cloud-init
   script), it re-runs `warp-relay-apply`.
2. **Stall detection** — if a mapping *was* carrying traffic and its FORWARD counter froze for
   75 s, it flushes conntrack entries for that destination (stuck NAT state after the far end
   restarted). A mapping that has never carried traffic is idle, not stalled, and is left alone.

## The conntrack boot-order trap (and why v7 exists)

UDP tunnels through a DNAT relay die after 30 s of silence unless
`net.netfilter.nf_conntrack_udp_timeout` is raised. Setting it in `sysctl.d` is not enough:
`systemd-sysctl` runs **before** the `nf_conntrack` module is loaded, so the key does not exist
yet, the write is silently skipped, and the module later comes up with the kernel defaults.
Everything looks fine on a running machine (someone ran `sysctl --system` by hand) and breaks
after the next reboot.

Warp Relay v7 fixes this three ways: `nf_conntrack` is listed in `modules-load.d` so it loads
before sysctl; `warp-relay-sysctl-reapply.service` re-applies the file after the network is up;
and `warp-relay-apply` sets the values itself. Diagnostic on any box:

```bash
journalctl -b -u systemd-sysctl | grep "Couldn't write"
```

## Cloudflare WARP preset

The wizard can add `relay:4500 → engage.cloudflareclient.com:2408`. 2408 is WARP's WireGuard
data port; a relay to `:4500` on the Cloudflare side never answers. Point your WARP/WireGuard
config `Endpoint` at `relay-ip:4500`.

## Files installed

| path | purpose |
|---|---|
| `/usr/local/bin/relay` | this script, TUI mode |
| `/usr/local/bin/warp-relay-apply` | idempotent rule applier (`-C \|\| -A` per rule) |
| `/usr/local/bin/warp-relay-watchdog` | watchdog loop |
| `/etc/warp-relay/mappings.conf` | mappings |
| `/etc/sysctl.d/90-warp-relay.conf`, `/etc/modules-load.d/warp-relay-conntrack.conf` | kernel settings |
| `warp-relay-sysctl-reapply`, `warp-relay-apply`, `warp-relay-watchdog` (systemd) | boot order: modules → sysctl → rules → watchdog |
| `/var/log/warp-relay.log` | log (also in journald) |

Uninstall: `relay` → Services → Uninstall, then `rm -rf /etc/warp-relay`.

## Privacy note

The *Connected clients* screen looks up client IPs on `ip-api.com` (plain HTTP, batch of up to
100 IPs) to show country and ISP. Nothing else leaves the box. Disable by not opening that screen.

## License

MIT. Built and battle-tested on a fleet of relay hubs serving users behind DPI filtering
since 2026; the fixes in v7 are all things that bit us in production.

---

## Русская версия

**Warp Relay** превращает VPS в прозрачное UDP-реле: клиент подключается к `ip-реле:порт`,
ядро через DNAT + MASQUERADE отдаёт поток на настоящий VPN-сервер (WireGuard, AmneziaWG,
Cloudflare WARP, Hysteria, любой UDP). Без userspace-прокси и лишней задержки, с хостнеймами
в качестве целей, со сторожем, который чинит правила и зависший conntrack, и с TUI, где видно
трафик по каждому маппингу и каждому клиенту.

**Установка:** `bash <(curl -fsSL https://raw.githubusercontent.com/BlackSysShark25/warp-relay/main/install.sh)`,
дальше команда `relay`.

**Конфиг:** `/etc/warp-relay/mappings.conf`, строка = `SRC_IP SRC_PORT DST_HOST DST_PORT LABEL`.
Цель может быть доменом, он переразрешается автоматически.

**Что чинит v7 по сравнению с ранними версиями:**

* правило DNAT срабатывает только на локальные адреса реле (`--dst-type LOCAL`) и не перехватывает
  транзитный UDP других сервисов;
* проверка правил через `iptables -C`, а не grep, поэтому повторный запуск больше не плодит дубли;
* сторож отличает «маппингом никто не пользуется» от «сессия зависла» и не чистит conntrack впустую
  (раньше — десятки тысяч ложных STALL в сутки);
* `nf_conntrack` грузится до `systemd-sysctl`, плюс юнит повторного применения sysctl после
  поднятия сети: таймауты 120/180 с переживают ребут, а не откатываются к 30 с;
* пресет WARP ведёт на порт **2408**, а не 4500 (4500→4500 никогда не работал).

Лицензия MIT.
