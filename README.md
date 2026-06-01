# ferrogate

## Description

Deploys [FerroGate](https://github.com/felipe-quintella/FerroGate) — the
high-availability, post-quantum-secure, TPM 2.0-attested machine-identity
system — as containers managed by `systemd`.

FerroGate ships two server binaries in a single image:

- **CMIS** — Central Machine Identity Service (gRPC, default port `8443`).
- **MIA** — Machine Identity Agent (host daemon).

This module pulls the image, creates a dedicated unprivileged service account,
lays out the on-disk directories on top of
[`ffquintella-baseapp`](https://github.com/ffquintella/puppet-baseapp), wires up
SELinux so the bind-mounted host directories are reachable, and runs each
service under `systemd`:

- **Podman (preferred)** — rootless
  [Quadlet](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)
  `.container` units owned by the dedicated user, started through the user's
  `systemd` instance (linger enabled).
- **Docker** — a plain system unit under `/etc/systemd/system/` whose
  `ExecStart` runs `docker run`, managed by the native `service` resource.

The runtime is auto-detected (podman preferred over docker) via the
`ferrogate_container_runtime` fact, or pinned with the `runtime` parameter.

## Directory layout

Directories build on the baseapp roots, below a `ferrogate` sub-directory and an
optional **environment variant** (empty by default):

```
/srv/application-config/ferrogate[/<app_environment>]/{cmis,mia}.env
/srv/application-data/ferrogate[/<app_environment>]/audit   # CMIS WORM audit store
/srv/application-logs/ferrogate[/<app_environment>]         # traced output
```

## Usage

### Defaults — both services, rootless podman

```puppet
include ferrogate
```

### Pull from a private registry, pin a tag, use docker

```puppet
class { 'ferrogate':
  runtime   => 'docker',
  registry  => 'registry.example.com/fgv',
  image_tag => '1.4.0',
}
```

### Per-environment deployment

```puppet
class { 'ferrogate':
  app_environment => 'staging',
}
```

### CMIS only

```puppet
class { 'ferrogate':
  mia_enable => false,
}
```

All parameters can be driven from Hiera.

## Reference

Key parameters (see the puppet-strings docs in
[`manifests/init.pp`](manifests/init.pp) for the full list):

| Parameter             | Default          | Description                                              |
| --------------------- | ---------------- | -------------------------------------------------------- |
| `runtime`             | `'auto'`         | `'auto'`, `'podman'` or `'docker'`.                      |
| `registry`            | `undef`          | Optional registry host/namespace for the image.         |
| `image_name`          | `'ferrogate'`    | Image repository name.                                   |
| `image_tag`           | `'latest'`       | Image tag.                                               |
| `app_environment`     | `''`             | Environment-variant directory level (empty = none).     |
| `user` / `group`      | `'ferrogate'`    | Dedicated unprivileged service account.                 |
| `uid` / `gid`         | `10001`          | IDs for the account (match the image).                  |
| `cmis_enable`         | `true`           | Deploy CMIS.                                             |
| `cmis_listen`         | `'0.0.0.0:8443'` | `CMIS_LISTEN` inside the container.                      |
| `cmis_port`           | `8443`           | Host port published for CMIS.                            |
| `cmis_container_port` | `8443`           | Container port CMIS listens on (match `cmis_listen`).    |
| `mia_enable`          | `true`           | Deploy MIA.                                              |
| `mia_tpm_device`      | `'/dev/tpmrm0'`  | Host TPM device handed to MIA.                           |
| `mia_skip_hardening`  | `true`           | Set `FERROGATE_SKIP_HARDENING=1` (containers can't meet the full profile). |
| `manage_selinux`      | `true`           | Apply SELinux config (no-op when SELinux is disabled).   |
| `selinux_relabel`     | `'Z'`            | Volume relabel mode (`Z`/`z`/`none`).                    |

### Facts

- `ferrogate_container_runtime` — `'podman'`, `'docker'` or `nil`, used when
  `runtime => 'auto'`.

## Limitations

- Linux only. Supported on the RedHat and Debian families (see
  `metadata.json`).
- **MIA in a container** cannot satisfy FerroGate's host-hardening profile
  (enforced IMA, seccomp install, privilege drop). `mia_skip_hardening` defaults
  to `true`; for a production MIA host that runs the full profile, set it to
  `false` on a host prepared for it, or run MIA outside a container.
- Rootless podman requires `systemd` linger and `subuid`/`subgid` ranges for the
  service user (the module enables linger; most distros seed the ID ranges on
  user creation).

## Development

Validate and test with [Regent](https://github.com/felipe-quintella/regent)
(never `pdk`):

```sh
regent validate
regent test
```

Author: Felipe Quintella
License: Apache-2.0
