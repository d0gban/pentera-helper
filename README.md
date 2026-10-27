# pentera-helper

One script for operating a Pentera **main node** on Ubuntu: find out why it failed, change its network
(static/DHCP) safely across subnets, and stop the clock from breaking its certificates on dual-boot laptops.

## Install

```bash
# from a clone
sudo ./install.sh --tz Asia/Manila

# or one line (public repo, no token needed)
curl -fsSL https://raw.githubusercontent.com/d0gban/pentera-helper/main/install.sh | sudo bash -s -- --tz Asia/Manila
```

This installs `/usr/local/sbin/pentera-helper` and runs `fix-time` (below). Remove with `sudo ./install.sh --uninstall`.
`install.sh --help` lists all options.

## Commands

| Command | What it does | Reboots? |
|---|---|---|
| `diagnose [--net\|--iface\|--time]` | Why did it fail? Always prints network info, interface roles, time and certificates, then a plain-language verdict. | no |
| `status` | Read-only overview: NICs, roles, netplan mode, time, staged change, last verification. | no |
| `wizard` | Interactive static/DHCP setup. | only if you confirm |
| `set-static --ip A --cidr N --gw G [--dns a,b] [--iface IF] [--verify-ip a,b]` | Static IP. Dry-run unless `--apply`. | with `--apply` |
| `set-dhcp [--iface IF] [--dns a,b] [--verify-ip a,b]` | DHCP. Dry-run unless `--apply`. | with `--apply` |
| `sync-iface [--iface IF] [--verify-ip a,b]` | Realign management/attack/compose to the real NIC. | with `--apply` |
| `fix-time [--tz Area/City] [--rtc local\|utc\|auto]` | Time guardrails (see below). | no |
| `regen-certs [--force]` | Re-mint node/UI certificates on the current clock (CA untouched). | restarts Pentera |
| `commit` / `rollback` | Accept a staged change without the check / restore the last backup. | rollback reboots |

`--apply --no-reboot` stages a change that is applied and verified on the next reboot.

## How a network change works

1. Backs up netplan, `network.conf` and the compose files (`/etc/pentera/backup/helper/net-*`).
2. Writes the new config and syncs the interface into **all three** places (netplan, `network.conf`, compose).
3. Reboots (10 s countdown, Ctrl-C cancels).
4. After boot it checks itself (within 90 s, ping or ARP if ping is blocked). The change passes if the **gateway
   answers, or any `--verify-ip` host does**. Pentera's certificates are re-issued for the new IP by Pentera itself;
   the helper regenerates them if they come out future-dated.

| After boot | What happens |
|---|---|
| check passes | change **kept** |
| fails, and the old gateway answered when you ran `--apply` (you are still on the old network) | old config **restored**, one more reboot |
| fails, and the old gateway was already silent (you moved to another network) | new config **kept**, no second reboot: restoring the old config could not work here. Fix it at the console with `pentera-helper wizard`. |

There is never a reboot loop: the check runs once, and removes itself before any automatic reboot, so one `--apply`
causes at most two reboots. To cancel a pending check by hand:
`sudo systemctl disable pentera-helper-verify && sudo rm /etc/pentera/backup/helper/pending.env`.

**Choosing `--verify-ip`** (the wizard asks for it as step 4):

- *Isolated VLAN, no internet:* give a neighbour or server on that VLAN, e.g. `--verify-ip 10.20.0.5`.
- *Internet, but the gateway blocks ping:* give public IPs, e.g. `--verify-ip 8.8.8.8,1.1.1.1`.
- Give both if you are not sure which kind of network you will land in. It is "gateway **or any** of them".

Result of the last check: `pentera-helper status` (log: `/etc/pentera/backup/helper/last-apply.log`; the last line
reads `RESULT: KEPT`, `REVERTED` or `FAILED-KEPT`).

**Gateway rules.** Pentera needs a default route to start, so `set-static` and the wizard reject a gateway that
the OS would drop: the network or broadcast address of the subnet (e.g. `.15` in a `/28`), an address outside the
subnet, or the box's own IP. On an isolated VLAN with no real router, still give an *unused* address of the subnet as the
gateway and use `--verify-ip` (a neighbour) for the connectivity check.

## Time and certificates (dual-boot laptops)

Windows keeps **local time** in the hardware clock; Ubuntu assumes UTC. After a Windows session Ubuntu boots hours
ahead, Pentera issues its node certificates on that wrong clock, NTP then corrects the time, and the certificates are
"not yet valid" — the node shows **Unavailable**.

`fix-time` prevents that:

- hardware clock mode `local` when a Windows partition exists (both OSes agree; set `--tz` to your zone),
- NTP `iburst` so the clock corrects in seconds,
- a systemd drop-in so Pentera waits (up to 180 s) for NTP before starting.

If it already happened: `sudo pentera-helper regen-certs`.

## Tested on

Ubuntu 22.04, Pentera V8.0.7 main node, one NIC, Lenovo laptop dual-booted with Windows (hardware clock case simulated
by writing local time to the RTC and rebooting). Not tested on multi-NIC boxes, VMs, or other Pentera versions.
Treat the first run on a new environment with care and use the dry-run first.

## Notes

- Commands that change things need root (`sudo`). Everything is a dry-run until `--apply`.
- The helper never touches the Windows side and never edits the Pentera CA.
- No credentials are stored anywhere in this repo.
