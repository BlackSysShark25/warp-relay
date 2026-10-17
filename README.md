# Warp Relay

English | [Русский](README.ru.md)

Warp Relay turns a cheap VPS into a UDP relay for your VPN servers. Clients connect to
the relay, the Linux kernel forwards the packets to the real server with DNAT and
MASQUERADE, and the replies come back the same way. There is no proxy process in the
middle: nothing to buffer, nothing to crash, no CPU to speak of.

It was written for one practical problem. The VPN server is abroad, the clients sit
behind an ISP that blocks or throttles that server's address, and a second hop in a
"clean" location fixes it. The ports to forward are listed in a small text file, and a
watchdog keeps the rules and the kernel state in order after reboots, DNS changes and
stuck connections.

```
                  :51820  ->  wg.example.com:51820              (WireGuard / AmneziaWG)
client -> relay   :4500   ->  engage.cloudflareclient.com:2408  (Cloudflare WARP)
                  :40000  ->  203.0.113.10:51821
```

## Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/BlackSysShark25/warp-relay/main/install.sh)
```

Or clone the repository and run `sudo ./relay.sh`. The wizard installs the packages it
needs (iptables, conntrack, curl, jq, netfilter-persistent), writes the kernel settings,
creates three systemd units and the `relay` command, then asks for the first mappings.

Works on Debian 12 and 13 and on Ubuntu 22.04 and 24.04 with either iptables backend,
nft or legacy. The script does not switch the backend, so it can live next to existing
nftables, tproxy or VPN rules.

## Everyday use

```bash
sudo relay                       # console: dashboard, clients, mappings, services, log
sudo relay --update              # fetch the latest version from GitHub and reinstall
sudo warp-relay-apply            # apply the config; safe to run as often as you like
sudo warp-relay-apply --replace  # drop every relay rule and rebuild from the config
relay --check-update             # compare the installed version with GitHub
```

## Config

`/etc/warp-relay/mappings.conf`, one mapping per line. A copy with comments is in
[mappings.conf.example](mappings.conf.example).

```
# SRC_IP   SRC_PORT  DST_HOST_OR_IP               DST_PORT  LABEL
0.0.0.0    51820     wg.example.com               51820     wg-germany
0.0.0.0    4500      engage.cloudflareclient.com  2408      cloudflare-warp
0.0.0.0    40000     203.0.113.10                 51821     awg-finland
```

The first column is kept for readability only. The DNAT rule matches any local address
of the relay (`-m addrtype --dst-type LOCAL`). That matters on a box which also carries
transit traffic: packets passing through to other hosts on the same port are left alone.

The destination can be a hostname. It is resolved every time the rules are applied and
again by the watchdog, so moving a VPN server to a new IP is a DNS change and nothing
more.

## What the watchdog does

Every 25 seconds it walks the config.

* A mapping has lost its rules (a firewall reload, ufw, a cloud-init script): the apply
  script runs again.
* A mapping had traffic and its forward counter has not moved for 75 seconds: the
  conntrack entries for that destination are dropped. This clears NAT state that got
  stuck after the far end restarted.
* A mapping that never carried traffic is simply idle. Earlier versions treated that as a
  stall and flushed conntrack in a loop, writing tens of thousands of log lines a day.
  Version 7 does not.

## Conntrack and reboots

A UDP tunnel through a NAT relay dies after 30 seconds of silence unless
`nf_conntrack_udp_timeout` is raised. Writing it to `sysctl.d` looks like enough, but it
is not. `systemd-sysctl` runs before the `nf_conntrack` module is loaded, the key does
not exist yet, the write is skipped with a one-line journal message nobody reads, and
the module later starts with the defaults. On a running machine everything looks fine
because someone once ran `sysctl --system` by hand. After the next reboot the tunnels
start dropping again.

Version 7 handles it from three sides: `nf_conntrack` is listed in `modules-load.d` so it
comes up before sysctl, a small unit re-applies the file once the network is up, and the
apply script sets the values itself. To check any box:

```bash
journalctl -b -u systemd-sysctl | grep "Couldn't write"
```

An empty result is what you want.

## Cloudflare WARP

The wizard can add `relay:4500 -> engage.cloudflareclient.com:2408`. Port 2408 is the
WireGuard data port of WARP. Forwarding to 4500 on the Cloudflare side gets no answer,
and earlier versions shipped with exactly that bug. In your WARP or WireGuard client set
`Endpoint = relay-ip:4500`.

## What gets installed

| Path | Purpose |
|---|---|
| `/usr/local/bin/relay` | this script in console mode |
| `/usr/local/bin/warp-relay-apply` | applies the config; every rule is "check, then add", so no duplicates |
| `/usr/local/bin/warp-relay-watchdog` | the watchdog loop |
| `/etc/warp-relay/mappings.conf` | your mappings |
| `/etc/sysctl.d/90-warp-relay.conf`, `/etc/modules-load.d/warp-relay-conntrack.conf` | kernel settings |
| `warp-relay-sysctl-reapply.service`, `warp-relay-apply.service`, `warp-relay-watchdog.service` | boot order: module, sysctl, rules, watchdog |
| `/var/log/warp-relay.log` | log, also sent to journald |

To remove: `relay`, then Services, then Uninstall, then `rm -rf /etc/warp-relay`.

## Updating

`sudo relay --update` downloads `relay.sh` from this repository, checks that it parses,
replaces `/usr/local/bin/relay` and lets the new version regenerate its helper scripts
and units. Your `mappings.conf` is not touched. `relay --check-update` only compares
versions.

## Similar projects

[arblark/cascad](https://github.com/arblark/cascad) does DNAT forwarding for TCP and UDP
from a bash menu, with IPv6 and BBR, but without a watchdog, hostname targets or the
conntrack fix described above. [zhboner/realm](https://github.com/zhboner/realm) and
[ginuerzh/gost](https://github.com/ginuerzh/gost) are userspace relays with far more
features and a process in the data path.

## Privacy

The "Connected clients" screen sends client IPs to ip-api.com over plain HTTP to show
country and ISP. Nothing else leaves the machine. If you do not want that, do not open
that screen.

## License

MIT. Warp Relay runs on the relay hubs of a small VPN service; every fix in version 7 is
something that broke there first.
