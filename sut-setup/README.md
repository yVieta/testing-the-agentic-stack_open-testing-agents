# iacSUT

## Usage
```bash
terraform init
terraform apply
```

### External access

Services are published on `0.0.0.0` by default (`bind_address`) so they are
reachable from the LAN, and `expose_public = true` opens all published TCP ports
in iptables. The `external_urls` and `exposure` outputs describe what is exposed.
Set `bind_address = "127.0.0.1"` and `expose_public = false` to keep everything
localhost-only.

## Project layout

```
.
├── main.tf        # local_file quadlets + null_resource install/start steps
├── providers.tf   # local + null providers
├── variables.tf   # tunables (images, ports, credentials)
├── outputs.tf     # managed services and URLs
└── quadlet/       # Quadlet templates (*.container.tftpl)
```

## Teardown

```bash
systemctl --user stop <service-name>
terraform destroy
```
