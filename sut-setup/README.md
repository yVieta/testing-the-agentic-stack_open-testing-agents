# iacSUT

Declarative rootless deployment of the system-under-test (Juice Shop + Grafana,
proxied by nginx) as Podman Quadlet **user** services. No root required: no
package installs, no firewall changes, and services are bound to `127.0.0.1`
only.

## Usage
```sh
tofu init
tofu plan
tofu apply
```

This writes the Quadlet unit files into `~/.config/containers/systemd`, then
starts the `sut.pod` user pod (ignore the "no doas" concern — the module no
longer uses root).

### Internal-only exposure

All services publish on `127.0.0.1` (`bind_address`), so they are reachable
only from this host — agents reach them via `Network=host`, never from the LAN.
No iptables/nftables rules are touched. The `exposure` output describes what is
published.

Ports (all on localhost):

- `:8080` — nginx proxy (default virtual host -> Juice Shop)
- `:3000` — Juice Shop directly
- `:3001` — Grafana directly

Inside the pod, Juice Shop listens on `3000` and Grafana on `3001`
(`GF_SERVER_HTTP_PORT`), so they share the pod network namespace without
colliding. nginx routes `Host: grafana.sut` to the Grafana upstream.

## Project layout

- `main.tf` — writes the Quadlet unit files and starts the rootless services
- `providers.tf` — local + null providers
- `variables.tf` — tunables (images, ports, credentials)
- `outputs.tf` — managed services and URLs
- `quadlet/` — Quadlet templates (`*.container.tftpl`, `sut.pod.tftpl`)
- `nginx/default.conf.tftpl` — nginx virtual-hosts template

## Start / Stop

The desired service state is controlled by the `service_state` variable. Stop
the pod without destroying anything, and start it again later:

```bash
tofu apply -var service_state=stopped   # stop quadlet user services
tofu apply -var service_state=running    # start them again (default)
```

## Teardown

```bash
systemctl --user stop sut-pod.service
tofu destroy
```