# open-testing-agents-paiselfhost

**three Raspberry Pis running NixOS**, coordinated over **MQTT**. The target
is a local web server reachable from all three Pis.

```
                 ┌─────────────────────────┐
                 │   local web server      │  (the app under test, on the LAN)
                 └────────────┬────────────┘
                              │ http (10.0.0.20)
        ┌─────────────┬───────┴────────┬─────────────┐
        ▼             ▼                 ▼
  ┌───────────┐ ┌───────────┐  ┌──────────────┐  ┌─────────────┐
  │ PI 1      │ │ PI 2      │  │ PI 3         │  │ PI 4        │
  │ e2e test  │ │ pentester │  │ test manager │  │ MQTT broker │
  │ engineer  │ │           │  │              │  │ (mosquitto) │
  └───────────┘ └───────────┘  └──────────────┘  └─────────────┘
        └─────────────── MQTT (TLS 8883) ────────────┘
```

Each Raspberry Pi runs **one agent** and one MQTT worker. The workers chain
results: e2e → pentester → test manager → final report, all over MQTT topics.

## Architecture

| Topic                    | Published by   | Consumed by       | Payload                        |
|--------------------------|----------------|-------------------|--------------------------------|
| `crew/start`             | trigger (you) | PI 1 (e2e)        | anything (kickoff)             |
| `crew/pentester/input`   | PI 1 (e2e)     | PI 2 (pentester)  | playwright output              |
| `crew/manager/input`     | PI 2 (pentester)| PI 3 (manager)   | security findings              |
| `crew/final`             | PI 3 (manager) | monitor/dashboard | final markdown report          |
| `crew/status/<role>`     | each worker    | monitor           | JSON lifecycle state           |

- The previous phase's output is saved to `previous_output.md` in the
  worker's working directory (`/var/lib/dhallcrew/<role>`) and read via the
  agent's `FileReadTool`; the final `report.md` lives there too.
- Non-secret settings (broker host, `TARGET_URL`, TLS CA, topic prefix) come
  from NixOS. Broker credentials are separate secret files.

## Repo layout

```
.dhall/                  Dhall source of truth (agents + per-PI crews)
  Types.dhall            crewAI JSON schema as Dhall types
  e2e_test_agent.dhall   pentester_agent.dhall   test_manager_agent.dhall
  crews/pi{1,2,3}_*.dhall
worker/worker.py         MQTT worker (one per Pi; subscribes, runs crewai, publishes)
nix/
  flake.nix              NixOS machines: 3 worker Pis + broker
  modules/crew-worker.nix   NixOS module: worker service + Dhall->JSON build
  modules/mqtt-broker.nix   NixOS module: mosquitto (TLS, ACL, firewall)
  modules/network.nix       WiFi module (reads nix/network-secrets.nix)
  modules/sd-image-systemd-boot.nix  SD image builder (U-Boot + systemd-boot)
  hosts/*.nix            per-host configuration
  network-secrets.nix    YOUR WiFi SSID + PSK (gitignored - copy the example)
  network-secrets.example.nix  template for network-secrets.nix
  secrets.env.example    template for worker secret files
Makefile                 Dhall -> JSON crews (make) + NixOS images (make images)
build/                   generated per-PI crews (gitignored)
```

## Requirements

- Dhall tooling plus `make` and `jq` for local dev (`make`): `dhall-to-json`
- Three Raspberry Pis + one broker host, all running **NixOS**
  (aarch64-linux; Raspberry Pi OS optional for quick local experiments)
- A local web server to test, reachable from every Pi

## Quick local experiment (no NixOS yet)

```sh
make                             # .dhall -> build/pi1-e2e, pi2-pentester, pi3-manager
pip install -e .                 # crewai[tools] + paho-mqtt
# edit build/<role>/.env         (broker + target + agent role)
cd build/pi1-e2e && python3 ../../worker/worker.py --verbose
# ...repeat on the other two roles, then:
mosquitto_pub -h BROKER -t crew/start -m 'go'
```

## NixOS deployment

### 1. Network

- Static IPs on a dedicated LAN/VLAN. Example (edit in `nix/hosts/`):
  - `10.0.0.10` broker, `10.0.0.11` PI1, `10.0.0.12` PI2, `10.0.0.13` PI3,
    `10.0.0.20` target server.
- Firewall: workers only ever reach *out* (ssh inbound is opened by
  `nix/hosts/common.nix`); the broker opens `1883/8883`.

Wi-Fi is optional and configured at build time:
- systemd-networkd (`systemd.network.enable`, `common.nix`) does DHCP/addressing
  (wired preferred over wifi via route metric); `wpa_supplicant`
  (`nix/modules/network.nix`) does the 802.11 auth.
- `nix/network-secrets.nix` (gitignored) holds the SSID + the WPA2 pre-shared
  key as a 64-hex string. Copy `nix/network-secrets.example.nix` to create it
  (the example shows how to derive the hash with `wpa_passphrase` /
  PBKDF2-HMAC-SHA1). No extra scripts: the flake reads the file at build time
  via an absolute `path:` input, so only the *derived hash* ever enters the Nix
  store, never the clear passphrase.

Ethernet-only hosts can omit `psk` (or leave it empty) in
`network-secrets.nix`; `crewNetwork.ssid`/`psk` then stay null and wifi is
not configured.

### 2. Broker secrets + TLS (once, on the broker)

Secrets live in plain files under `/etc/dhallcrew/` - never in the Nix store.
Create them manually on the broker:

- `mosquitto_passwd -b <tmp> <user> <password> && cut -d: -f2 <tmp>` -> one
  hash per file in `/etc/dhallcrew/passwd/<user>` (see `mqtt-broker.nix`).
- `openssl req -x509 ...` -> private CA `ca.crt` + broker `server.key`/
  `server.crt` with `subjectAltName` for the broker host in `/etc/dhallcrew/certs/`.
- a `<role>.env` per worker with `BROKER_USERNAME` / `BROKER_PASSWORD`.

Then copy the CA to every worker:

```sh
sudo scp /etc/dhallcrew/certs/ca.crt pi1-e2e:/etc/dhallcrew/certs/
sudo scp /etc/dhallcrew/certs/ca.crt pi2-pentester:/etc/dhallcrew/certs/
sudo scp /etc/dhallcrew/certs/ca.crt pi3-manager:/etc/dhallcrew/certs/
# fill in /etc/dhallcrew/<role>.env BROKER_PASSWORD on each host
```

The CA must be the same on every host, so it is not stored in the Nix store.
WiFi credentials come from `nix/network-secrets.nix` (see §1), not here.

### 3. Deploy with nixos-rebuild

On each Raspberry Pi and the broker (repo must be git-committed for flakes):

```sh
git add -A && git commit -m "flaky: initial crew config"   # once
nixos-rebuild switch --flake .#pi1-e2e       # on PI 1
nixos-rebuild switch --flake .#pi2-pentester # on PI 2
nixos-rebuild switch --flake .#pi3-manager   # on PI 3
nixos-rebuild switch --flake .#broker        # on the broker
```

or from a control machine over SSH:

```sh
nixos-rebuild switch --flake .#pi1-e2e --target-host root@10.0.0.11 --build-host localhost
```

### 3b. Build a full SD card image instead

Each host also ships a flashable Raspberry Pi SD image built from the same
host module (boot chain: video-core firmware -> U-Boot -> **systemd-boot**,
see `nix/modules/sd-image-systemd-boot.nix`). Build them all, or one:

```sh
make images                              # or: make pi1-e2e-sd-image ...
# results in nix/result/sd-image/<host>.img.zst:
#   pi1-e2e-sd-image, pi2-pentester-sd-image, pi3-manager-sd-image, broker-sd-image
```

`make check` runs `nix flake check` instead of building. Write the image to
an SD card, then insert it - the root partition auto-grows on first boot
(`sdImage.expandOnBoot`):

```sh
zstd -d < nix/result/sd-image/pi1-e2e.img.zst | sudo dd of=/dev/mmcblk0 bs=4M status=progress
```

The images are `aarch64-linux` derivations, so build them on a Pi (or any
aarch64 machine / remote builder), or enable QEMU+binfmt on an x86 box first.

> **Note:** this project rewrote its bootloader to systemd-boot (U-Boot
> chainloads the ESP from the same FAT FIRMWARE partition). The first boot of
> an image offers a single NixOS entry; after `nixos-rebuild switch` runs on
> the Pi, `installBootLoader` manages generations on that ESP like on any
> other systemd-boot NixOS. (In the pinned nixpkgs, the official aarch64
> sd-image builder still hardcodes extlinux, hence the custom builder here.)

### 4. First boot behavior

- `ensure-worker-venv` creates a Python venv at `/opt/dhallcrew/venv`
  (crewai + paho-mqtt; needs network, done once).
- `crew-worker-<role>` stages the compiled Dhall configs into
  `/var/lib/dhallcrew/<role>`, reads `/etc/dhallcrew/<role>.env`, and listens
  on its MQTT input topic.

### 5. Run a test run + monitor

```sh
mosquitto_pub -h 10.0.0.10 -p 8883 --cafile /etc/dhallcrew/certs/ca.crt \
  -u trigger -P '...' -t crew/start -m 'go' -q 1

mosquitto_sub -h 10.0.0.10 -p 8883 --cafile /etc/dhallcrew/certs/ca.crt \
  -u monitor -P '...' -t 'crew/status/#' -v       # lifecycle
mosquitto_sub ... -t crew/final -v                # final report
ssh pi1-e2e 'systemctl status crew-worker-pi1-e2e; journalctl -u crew-worker-pi1-e2e -f'
cat /var/lib/dhallcrew/pi3-manager/report.md       # results (on PI 3)
```

## Editing configuration

- Agents/crews/tasks: edit `.dhall/*`, then either re-run `make` for
  local previews or rebuild via NixOS (the worker module compiles Dhall →
  JSON itself during `nixos-rebuild`, so `build/` is just a preview).
- Dhall is type-safe: typos, wrong fields, invalid process values fail at
  compile time.
- NixOS settings: edit `nix/hosts/*.nix`, `nix/modules/*`.

## Security notes

- MQTT uses TLS (8883) with a private CA pinned in every worker; drop the
  1883 debugging listener (`mqttBroker.allowPlaintext = false`) in
  production.
- ACLs restrict each worker to exactly the topics it needs; the trigger and
  monitor identities are separate.
- SSH is key-only on every host (`PasswordAuthentication = false`).
- The crew target must be firewalled so scanning agents only reach the
  designated server/VLAN.
- Secrets never enter the Nix store (wifi -> `network-secrets.nix`, broker TLS
  & MQTT credentials -> `/etc/dhallcrew/*`); consider sops-nix/age for more
  hosts.

## Troubleshooting

- `crew-worker-*` not starting → `journalctl -u ensure-worker-venv` (venv
  bootstrap needs network once), check `/etc/dhallcrew/<role>.env` exists.
- `crewai` not found → venv missing or `crewai run` failing inside venv:
  `sudo -u crew-worker-<role> -g crew-worker-<role> ...` or inspect
  `worker.py` `_run_crew` output in the journal.
- TLS handshake errors → CA mismatch; re-sync `ca.crt` from the broker.
- `dhall-json` not in your nixpkgs → override `crewWorker.crewConfigs`
  (see module) or compile first with `make` and point it at the
  `build/` outputs.

## Further Notes 
- In the resource folders are our sources listed that we used

