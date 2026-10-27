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
| `set-static --ip A --cidr N --gw G [--dns a,b] [--iface IF]` | Static IP. Dry-run unless `--apply`. | with `--apply` |
| `set-dhcp [--iface IF] [--dns a,b]` | DHCP. Dry-run unless `--apply`. | with `--apply` |
| `sync-iface [--iface IF]` | Realign management/attack/compose to the real NIC. | with `--apply` |
| `fix-time [--tz Area/City] [--rtc local\|utc\|auto]` | Time guardrails (see below). | no |
| `regen-certs [--force]` | Re-mint node/UI certificates on the current clock (CA untouched). | restarts Pentera |
| `commit` / `rollback` | Accept a staged change without the check / restore the last backup. | rollback reboots |

`--apply --no-reboot` stages a change that is applied and verified on the next reboot.

## How a network change works

1. Backs up netplan, `network.conf` and the compose files (`/etc/pentera/backup/helper/net-*`).
2. Writes the new config and syncs the interface into **all three** places (netplan, `network.conf`, compose).
3. Reboots (10 s countdown, Ctrl-C cancels).
4. After boot it checks itself: the gateway must answer within 90 s. If so the change is **kept**; if not, the
   old config is **restored** and the box reboots once more. Pentera's certificates are re-issued for the new IP
   by Pentera itself; the helper regenerates them if they come out future-dated.

Result of the last check: `pentera-helper status` (log: `/etc/pentera/backup/helper/last-apply.log`).

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
