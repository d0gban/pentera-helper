# pentera-helper

All-in-one ops helper for a Pentera **main node** on Ubuntu, in a single bash script. It tells you in plain language
why the service or node failed, changes the network (static/DHCP) safely with a self-verifying reboot, keeps the
interface names Pentera uses in sync with the real NIC, and stops a dual-boot clock from breaking the certificates.

> **Commands that change things need root.** Every network command is a dry-run until `--apply` (the wizard asks first).

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/d0gban/pentera-helper/main/install.sh | sudo sh
```

The installer:

- installs the `pentera-helper` command to `/usr/local/sbin`;
- runs `pentera-helper fix-time` — the time guardrails (see [Time and certificates](#time-and-certificates-dual-boot-laptops));
- checks the download (bash shebang, looks like pentera-helper, `bash -n` syntax check) before installing;
- warns, without stopping, when something the helper relies on is missing (`/etc/pentera`, `netplan`, `docker`, `ntp`).

Options (pass after `sudo sh -s --`):

```sh
curl -fsSL https://raw.githubusercontent.com/d0gban/pentera-helper/main/install.sh | sudo sh -s -- --tz Asia/Manila
curl -fsSL .../install.sh | sudo sh -s -- --rtc local       # hardware clock mode: auto (default), local, utc
curl -fsSL .../install.sh | sudo sh -s -- --no-fix-time     # install the command only
curl -fsSL .../install.sh | sudo sh -s -- --ref v1.0        # pin a branch/tag
curl -fsSL .../install.sh | sudo sh -s -- --uninstall       # add --force if a network change is still staged
```

Running the same command again updates the helper in place. From a clone: `sudo sh install.sh` uses the local
`pentera-helper.sh`.

**Requirements:** Ubuntu/Debian with systemd (tested on Ubuntu 22.04, Pentera V8.0.7), `bash`, `ip`, `netplan`,
`openssl`. `ntp` is needed for the time guardrail to actually wait for sync.

## Usage

```sh
sudo pentera-helper diagnose                     # why did it fail? network, roles, time, certs, verdict
sudo pentera-helper status                       # read-only overview, incl. a staged change + last verification
sudo pentera-helper wizard                       # interactive static/DHCP setup
sudo pentera-helper sync-iface --apply           # realign every NIC name to the real NIC, reboot, verify
sudo pentera-helper set-static --ip 10.20.0.10 --cidr 24 --gw 10.20.0.1 --dns 10.20.0.2 --verify-ip 10.20.0.5
sudo pentera-helper regen-certs                  # re-mint node/UI certs on the current clock
```

| Command | What it does | Reboots? |
|---|---|---|
| `diagnose [--net\|--iface\|--time]` | Always prints network info, interface roles, time and certificates, then a plain-language verdict. | no |
| `status` | NICs, roles, netplan, time, staged change, last verification. | no |
| `wizard` | Interactive: every option of a network change, no flags needed. | `y` = now, `l` = next reboot |
| `set-static --ip A --cidr N --gw G [--dns a,b] [--iface IF] [--verify-ip a,b]` | Static IP. | with `--apply` |
| `set-dhcp [--iface IF] [--dns a,b] [--verify-ip a,b]` | DHCP. | with `--apply` |
| `sync-iface [--iface IF] [--verify-ip a,b]` | Move the NIC name everywhere (netplan too); IP settings untouched. | with `--apply` |
| `fix-time [--tz Area/City] [--rtc local\|utc\|auto]` | Time guardrails. | no |
| `regen-certs [--force]` | Re-mint node/UI certificates (CA untouched). | restarts Pentera |
| `commit` / `rollback` | Accept a staged change without the check / restore the last backup. | rollback reboots |

`--apply --no-reboot` stages a change that is applied and verified on the next reboot.

## The wizard

`sudo pentera-helper wizard` asks for everything a network change needs, so you never have to remember a flag:

| Step | Asks | Same as |
|---|---|---|
| 1. Management interface | pick from the real NICs (Enter = the detected one) | `--iface` |
| 2. IP assignment | **Static** (IP, prefix, gateway, DNS) · **DHCP** (optional DNS override) · **Keep current** (only move the settings to the chosen NIC) | `set-static` · `set-dhcp` · `sync-iface` |
| 3. Attack interface | same as management by default | |
| 4. Connectivity check | extra IPs; after the reboot the change passes if the gateway **or** any of them answers | `--verify-ip` |
| 5. Clock | timezone and hardware-clock mode (suggests `Asia/Manila` + `local` on a Windows dual-boot still set to UTC) | `fix-time --tz --rtc` |
| Review | `[y]` apply + reboot now · `[l]` apply, reboot later · `[N]` abort (writes nothing) | `--apply` · `--no-reboot` |

After an adapter swap, pick **Keep current** in step 2: the IP settings stay, only the NIC name moves.

## How a change is applied

1. Backs up netplan, `network.conf`, `dns_config.json` and the compose files (`/etc/pentera/backup/helper/net-*`).
2. Writes the new config and syncs the interface into **all four** places Pentera reads it from (see below).
3. Sets the hardware clock from the synced clock, then reboots after a live `Rebooting in 10s...` countdown
   (Ctrl-C cancels the reboot; the change stays staged for the next one).
4. After boot it checks itself within 90 s (ping, or ARP when ping is blocked), then waits for Pentera and re-checks
   the interface roles and the certificates.

| After boot | What happens |
|---|---|
| gateway or a `--verify-ip` host answers | change **kept** |
| silent, and the old gateway answered when you applied (still on the old network) | old config **restored**, one more reboot |
| silent, and the old gateway was already silent (you moved networks) | new config **kept**, no second reboot — fix it at the console with `pentera-helper wizard` |

There is never a reboot loop: the check runs once and removes itself before any automatic reboot, so one apply causes
at most two reboots. Result: `pentera-helper status` (log `/etc/pentera/backup/helper/last-apply.log`, last line
`RESULT: KEPT`, `REVERTED` or `FAILED-KEPT`). To cancel a pending check by hand:
`sudo systemctl disable pentera-helper-verify && sudo rm /etc/pentera/backup/helper/pending.env`.

**Choosing `--verify-ip`:** isolated VLAN with no internet → a neighbour on that VLAN (`10.20.0.5`); internet but the
gateway blocks ping → public IPs (`8.8.8.8,1.1.1.1`). Give both if unsure.

**Gateway rules.** Pentera needs a default route to start, so `set-static` and the wizard reject a gateway the OS
would drop: the network or broadcast address (e.g. `.15` in a `/28`), an address outside the subnet, or the box's own
IP. On an isolated VLAN with no router, still give an *unused* address of the subnet and use `--verify-ip`.

## Interface roles

Pentera names its NIC in four places. They must all name the same real NIC:

| Where | Key | Note |
|---|---|---|
| `/etc/netplan/00-installer-config.yaml` | `ethernets:` | the OS side |
| `/etc/pentera/network/network.conf` | `management_interface`, `attack_interface` | |
| `/etc/pentera/network/dns_config.json` | `pentera_network_interface` | **source of the compose value** |
| `/etc/pentera/compose/mgmt.yml` | `NETWORK_INTERFACE` | re-rendered from `dns_config.json` on every Pentera start |

Pentera writes these once at install and never updates them. USB adapters are named after their MAC
(`enx<mac>`), so swapping the adapter leaves stale names behind. Editing compose alone does not stick — Pentera
overwrites it from `dns_config.json` on its next start. `diagnose` flags any disagreement;
`sudo pentera-helper sync-iface --apply` fixes all four.

## Time and certificates (dual-boot laptops)

Windows keeps **local time** in the hardware clock; Ubuntu assumes UTC. After a Windows session Ubuntu boots hours
ahead, Pentera issues its node certificates on that wrong clock, NTP then corrects the time, and the certificates are
"not yet valid" — the node shows **Unavailable**.

`fix-time` (run by the installer) prevents that:

- hardware clock mode `local` when a Windows partition exists, so both OSes agree (set `--tz` to your zone);
- NTP `iburst`, so the clock corrects in seconds;
- a systemd drop-in so Pentera waits (up to 180 s) for NTP before starting.

If it already happened: `sudo pentera-helper regen-certs`.

## Notes

- Tested on Ubuntu 22.04, Pentera V8.0.7 main node, Lenovo laptop dual-booted with Windows, one USB NIC.
  Not tested on multi-NIC boxes, VMs, or other Pentera versions — use the dry-run first on a new environment.
- The helper never touches the Windows side and never edits the Pentera CA.
- No credentials are stored anywhere in this repo.
