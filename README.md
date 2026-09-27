# open-testing-agents-paiselfhost

**three Raspberry Pis with Nix**, coordinated over
**MQTT**. The target is a local web server reachable from all three Pis.

Every tool is pulled from the **nixpkgs** package set via the **Nix package
manager** — you do **not** need to be on NixOS. Host systems (the MQTT
broker, the SUT, optional GPU / model / database servers) are provisioned
with **Terraform/OpenTofu**.

```mermaid
graph TD
    SUT["<b>local web server</b><br/>system under test, on the LAN<br/>http IP_ADDRESS"]

    subgraph PIS["Raspberry Pis — one agent + one MQTT worker each"]
        direction LR
        PI1["<b>PI 1</b><br/>e2e engineer"]
        PI2["<b>PI 2</b><br/>pentester"]
        PI3["<b>PI 3</b><br/>test manager"]
    end

    subgraph SERVERS["64-bit GPU servers (provisioned via OpenTofu)"]
        direction LR
        BROKER["<b>MQTT broker</b>"]
        GPU["model, database"]
        MORE["extra...<br/>add more with GPU"]
    end

    SUT <-->|"http"| PI1
    SUT <-->|"http"| PI2
    SUT <-->|"http"| PI3

    BROKER <-->|"MQTT 1883 / 8883"| PI1
    BROKER <--> PI2
    BROKER <--> PI3
    BROKER <--> GPU
    BROKER <--> MORE

    classDef sut fill:#e8f0fe,stroke:#4285f4,color:#202124;
    classDef pi fill:#e6f4ea,stroke:#34a853,color:#202124;
    classDef server fill:#fef7e0,stroke:#fbbc04,color:#202124;
    class SUT sut;
    class PI1,PI2,PI3 pi;
    class BROKER,GPU,MORE server;
```

Each Raspberry Pi runs **one agent** and one MQTT worker. The workers chain
results: e2e → pentester → test manager → final report, all over MQTT topics.
The **64-bit servers with GPU** (broker plus any number of GPU servers) join the same network
over MQTT, so the crew can offload model inference and databases onto machines
with dedicated GPUs.

## Architecture

| Topic                    | Published by   | Consumed by       | Payload                        |
|--------------------------|----------------|-------------------|--------------------------------|
| `crew/start`             | trigger (we)   | PI 1 (e2e)        | anything (kickoff)             |
| `crew/pentester/input`   | PI 1 (e2e)     | PI 2 (pentester)  | playwright output              |
| `crew/manager/input`     | PI 2 (pentester)| PI 3 (manager)   | security findings              |
| `crew/final`             | PI 3 (manager) | monitor/dashboard | final markdown report          |
| `crew/status/<role>`     | each worker    | monitor           | JSON lifecycle state           |

- The previous phase's output is saved to `previous_output.md` in the
  worker's working directory (`build/<role>/`) and read via the agent's
  `FileReadTool`; the final `report.md` lives there too.
- Broker host, `TARGET_URL`, TLS settings and broker **credentials** live in
  `build/<role>/.env` (never committed); the roles' MQTT passwords are set on
  the broker.

## Tools from nixpkgs — no NixOS required

Installing nixpkgs in your non NixOS
```sh
curl -sSf -L https://install.lix.systems/lix | sh -s -- install
```

All packagess are in the flake.nix just run 
```sh
nix develop
```

That single shell is how the Pis are set up — the same commands work on the
Pis and on your dev machine.

## Repo layout

- `.dhall/` — crew + agent definitions (Dhall; the single source of truth)
- `worker/worker.py` — the MQTT worker each role runs
- `sut-setup/` — TF that configures the host systems (services)
- `hosts/`, `modules/` — optional NixOS config for the broker host
- `flake.nix` — the `nix develop` shell (nixpkgs as flake input)
- `Makefile` — compiles the crews (`make`)
- `resources/` — papers, `knowledge/`, `skills/` the agents use

## Requirements

- Three Raspberry Pis running **Raspberry Pi OS (Any Linux with Systemd, aarch64)**
- The **Nix package manager** (nixpkgs provides every tool; see above —
  NixOS is *not* required)
- A host system (x86_64 Linux) for the SUT + MQTT broker, set up with
  TF (`sut-setup/`)
- Optional: extra **64-bit server with GPU**, carrying a GPU to serve local models
  and databases to the crew
- A local web server to test, reachable from every Pi (the TF setup
  deploys Juice Shop for us): https://owasp.org/projects/juice-shop

## Quick local experiment

```sh
nix develop                          
make                                 # .dhall -> build/pi1-e2e, pi2-pentester, pi3-manager
python3 -m venv .venv && source .venv/bin/activate
pip install -e .                     # crewai[tools] + paho-mqtt
# per role: build/<role>/.env with broker + target + role, e.g.
cat > build/pi1-e2e/.env <<'EOF'
BROKER_HOST=10.0.0.10
BROKER_USERNAME=pi1-e2e
BROKER_PASSWORD=change-me
TARGET_URL=http://10.0.0.20
EOF
cd build/pi1-e2e && python3 ../../worker/worker.py --verbose
# ...repeat on the other two roles, then from anywhere:
mosquitto_pub -h BROKER -t crew/start -m 'go'
```

## Host systems via Terraform/OpenTofu 

The host machines (SUT + MQTT broker + Grafana) are **configured with
TF**, not hand-edited. `terraform` ships in `nix develop`.

```sh
cd sut-setup
terraform init
terraform apply
```

This installs podman, writes the Quadlet unit files and starts a pod with

- **EMQX** — the MQTT broker (1883 MQTT, 8083 WebSocket, 18083 dashboard)
- **Juice Shop** — the system under test (OWASP project)
- **Grafana** — metrics/dashboard
- **nginx** — reverse proxy on :80

Services bind to `0.0.0.0` by default so the Pis can reach them over the LAN;
tune `bind_address` / `expose_public` in `sut-setup/variables.tf`. Tear down
with `systemctl --user stop <service>` then `tofu destroy`. Details in
`sut-setup/README.md`.

## Adding extra servers (GPU / models / database)

Want more compute? Add another **64-bit server with GPU**, deploy your model
servers and databases there, and let it join the crew over MQTT — nothing on
the Pis changes. The nixpkgs-hosted tooling also lets you manage these servers
the same way (or keep them on NixOS via the optional `broker` deployment in
`flake.nix`).

## Further Notes

- In the `resources/` folder are our sources we used

## Disclaimer

- This project is mostly written without using any kind of Generative AI
- Only open models which are selfhosted are used in this project

## Contributions

- Contributions are welcomed but restrictive using generative AI. There must
  be at least a human behind the requests who needs to explain why they made
  the change.
