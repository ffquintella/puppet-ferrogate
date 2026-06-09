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

### Defaults — CMIS only, rootless podman

The standard image is CMIS-only, so MIA is off by default (see
[Limitations](#limitations)).

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

### Enable MIA as a container

Only against an image that bundles the `mia` binary, on a host prepared for the
MIA hardening profile (see [Limitations](#limitations)):

```puppet
class { 'ferrogate':
  mia_enable => true,
}
```

All parameters can be driven from Hiera.

### Transport TLS (hybrid-PQC)

CMIS terminates **hybrid-PQC TLS** (TLS 1.3, `X25519MLKEM768`-only) on its
listen port. This is **on by default** (`cmis_tls_enable => true`): the module
ensures a certificate exists, sets `CMIS_TLS_CERT` / `CMIS_TLS_KEY` for the
container, and bind-mounts the cert/key into it. FerroGate authenticates the
server by **SPKI pin**, not a CA chain, so a self-signed certificate is fine.

With no certificate supplied, the module generates a self-signed P-384 cert
(requires `openssl` on the host):

```puppet
include ferrogate   # TLS on; self-signed cert generated if none supplied
```

Supply your own PKI-issued certificate instead (e.g. from Hiera):

```puppet
class { 'ferrogate':
  cmis_tls_cert => file('/path/to/cmis.crt'),  # PEM chain, end-entity first
  cmis_tls_key  => file('/path/to/cmis.key'),  # matching PEM private key
}
```

The module writes the certificate's **SHA-384 SPKI pin** to
`<config_dir>/cmis.spki-pin.txt` (e.g.
`/srv/application-config/ferrogate/cmis.spki-pin.txt`) — that hex string is what
MIA clients pin to authenticate this CMIS node.

Disable TLS for a local dev / bring-up node (plaintext gRPC — never in
production):

```puppet
class { 'ferrogate':
  cmis_tls_enable => false,
}
```

> **Operator CLI over TLS:** with TLS on, the host wrapper targets an `https://`
> loopback endpoint. The in-container `ferrogate` CLI dials it over the F01
> hybrid-PQC transport and **auto-derives the SPKI pin from the mounted server
> certificate** (`/etc/ferrogate/tls/cmis.crt`), so it works out of the box — no
> extra trust configuration. This requires a `ferrogate` CLI with F01 support
> (≥ **0.15.0**); older, plaintext-only CLIs cannot talk to a TLS node — run
> those operator commands against a node with `cmis_tls_enable => false`, or use
> a TLS-aware client.

## MIA host agent (`ferrogate::mia`)

FerroGate ships the **Machine Identity Agent** as a native host package
(`ferrogate-mia`: a static `/usr/bin/mia` binary plus a `mia` systemd unit), not
in the server image. The `ferrogate::mia` class installs and configures that
agent and is **fully standalone** — declare it on any host that needs an agent,
with no dependency on the `ferrogate` server class, `baseapp`, or a container
runtime:

```puppet
class { 'ferrogate::mia':
  cmis_endpoint => 'https://cmis.prod.example.com:8443',
  cmis_spki_pin => '5f2e...c4',   # SHA-384 SPKI pin (lowercase hex)
}
```

The pin is the value the CMIS server node publishes at
`<config_dir>/cmis.spki-pin.txt` (e.g.
`/srv/application-config/ferrogate/cmis.spki-pin.txt`) — see
[Transport TLS](#transport-tls-hybrid-pqc). With a signed local-caller
allowlist for the helper API:

```puppet
class { 'ferrogate::mia':
  cmis_endpoint  => 'https://cmis.example.com:8443',
  cmis_spki_pin  => '5f2e...c4',
  allowlist_path => '/etc/ferrogate/allowlist.cbor',
  allowlist_key  => '/etc/ferrogate/allowlist.pub',
}
```

The class installs the package, manages `/etc/ferrogate`, renders the systemd
`EnvironmentFile` at `/etc/ferrogate/mia.env`, and enables/starts the `mia`
service. MIA is configured entirely through `FERROGATE_*` env variables; each
overrides the optional TOML file.

By default the package is assumed reachable through the node's existing
repositories. To add a custom `ferrogate-mia` repository, set
`manage_repo => true` and `repo_baseurl` — a `yumrepo` is declared on the RedHat
family, an apt source list on the Debian family, ordered before the package:

```puppet
class { 'ferrogate::mia':
  cmis_endpoint => 'https://cmis.example.com:8443',
  cmis_spki_pin => '5f2e...c4',
  manage_repo   => true,
  repo_baseurl  => 'https://repo.example.com/ferrogate/el9/x86_64',
  repo_gpgkey   => 'https://repo.example.com/ferrogate/RPM-GPG-KEY',
}
```

| Parameter (key ones)   | Default                     | Description                                              |
| ---------------------- | --------------------------- | -------------------------------------------------------- |
| `package_name`         | `'ferrogate-mia'`           | MIA OS package.                                          |
| `package_ensure`       | `'installed'`               | `ensure` for the package.                               |
| `manage_repo`          | `false`                     | Add a custom `ferrogate-mia` repo (needs `repo_baseurl`).|
| `repo_baseurl`         | `undef`                     | Repository URL (yumrepo `baseurl` / apt `deb` URI).     |
| `repo_gpgkey`          | `undef`                     | GPG key (RedHat URL/path; Debian `signed-by` keyring).  |
| `cmis_endpoint`        | `undef`                     | `FERROGATE_CMIS_ENDPOINT` — the CMIS server URL.        |
| `cmis_spki_pin`        | `undef`                     | `FERROGATE_CMIS_SPKI_PIN` — accepted SPKI pin (SHA-384).|
| `helper_socket`        | `'/run/ferrogate/mia.sock'` | Helper-API socket; its presence enables the helper API. |
| `allowlist_path`       | `undef`                     | Signed CBOR caller allowlist (requires `allowlist_key`).|
| `allowlist_key`        | `undef`                     | Enrollment public key that verifies the allowlist.      |
| `seccomp`              | `undef`                     | `FERROGATE_SECCOMP`: `enforce`/`audit`/`off`.           |
| `skip_hardening`       | `false`                     | Set `FERROGATE_SKIP_HARDENING=1` (dev only).            |
| `rust_log`             | `'info'`                    | `RUST_LOG` tracing filter.                              |

> This is distinct from the container-based `mia_enable` switch on the main
> `ferrogate` class (which runs `mia` inside the server image, only for images
> that bundle it — see [Limitations](#limitations)). `ferrogate::mia` is the
> way to run a real agent on a production host.

All parameters can be driven from Hiera; see the puppet-strings docs in
[`manifests/mia.pp`](manifests/mia.pp) for the full list.

## Operator CLI

When CMIS is enabled the module installs a host wrapper at
`/usr/local/bin/ferrogate`. The `ferrogate` operator CLI binary ships *inside*
the server image; the wrapper re-execs into the running `ferrogate-cmis`
container so the CLI's gRPC client reaches CMIS over the container's own
loopback — no published host port is needed. The wrapper's endpoint scheme
follows `cmis_tls_enable` (`https://` when TLS is on); over TLS the CLI pins the
mounted server certificate automatically (requires a CLI with F01 support — see
[Transport TLS](#transport-tls-hybrid-pqc)).

```console
$ ferrogate status
$ ferrogate list-svids
$ ferrogate revoke-host spiffe://example.org/host/abc
```

- **podman** — the wrapper `sudo`s to the rootless service user, then
  `podman exec`s the container. **docker** — it `sudo`s to root and
  `docker exec`s.
- A `/etc/sudoers.d/ferrogate-cli` drop-in lets members of the FerroGate group
  (`group`, default `ferrogate`) run the CLI without a password. Add operators
  to that group to grant access.
- Point at a different node with `--endpoint <url>` (or
  `FERROGATE_CMIS_ENDPOINT`); by default it talks to the local container.

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
| `cmis_tls_enable`     | `true`           | Terminate hybrid-PQC TLS on CMIS (else plaintext bring-up). |
| `cmis_tls_cert` / `cmis_tls_key` | `undef`| Supplied PEM cert chain + key (else self-signed is generated). |
| `cmis_tls_manage_cert`| `true`           | Generate a self-signed P-384 cert when none is supplied. |
| `cmis_tls_cert_cn`    | FQDN fact        | Subject CN for the generated cert (trust is by pin, not name). |
| `cmis_tls_cert_days`  | `3650`           | Validity (days) of the generated self-signed cert.       |
| `mia_enable`          | `false`          | Deploy MIA as a container (standard image is CMIS-only). |
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
- **MIA is not in the standard image.** The published FerroGate image is
  CMIS-only — it ships the `cmis` server and the `ferrogate` CLI, and its
  entrypoint expects the MIA host agent to be installed on each machine from its
  OS package, not run as a container. `mia_enable` therefore defaults to
  `false`; enabling it against the standard image makes the MIA unit fail
  (`exec: mia: not found`). Only set `mia_enable => true` against an image that
  actually bundles the `mia` binary. **To run a real agent, use the standalone
  [`ferrogate::mia`](#mia-host-agent-ferrogatemia) class**, which installs the
  `ferrogate-mia` host package instead.
- **CMIS TLS is on by default.** With TLS on, the host CLI wrapper targets an
  `https://` loopback; the in-container `ferrogate` CLI pins the mounted server
  cert automatically, which requires a CLI with F01 hybrid-PQC transport support
  (≥ **0.15.0**). Older, plaintext-only CLIs cannot talk to a TLS node —
  use `cmis_tls_enable => false` for those. Self-signed certificate generation
  requires `openssl` on the host; the module does not manage the `openssl`
  package (to avoid colliding with other modules on shared nodes). See
  [Transport TLS](#transport-tls-hybrid-pqc).
- **MIA in a container** also cannot satisfy FerroGate's host-hardening profile
  (enforced IMA, seccomp install, privilege drop). `mia_skip_hardening` defaults
  to `true`; for a production MIA host that runs the full profile, set it to
  `false` on a host prepared for it, or run MIA outside a container.
- Rootless podman requires `systemd` linger and `subuid`/`subgid` ranges for the
  service user. The module enables linger and, by default
  (`manage_subids => true`), registers the service user's range through
  **`baseapp::subid`**. baseapp owns `/etc/subuid` and `/etc/subgid` as concat
  targets, so several rootless apps on one node (e.g. ferrogate +
  `bastionvault`) each contribute a fragment and share one consistently-managed
  pair of files. **baseapp must be the only manager of those files:** if the
  `puppet/podman` module is also on the node, leave its `manage_subuid => false`
  (the default) so it does not declare a competing `Concat['/etc/subuid']`. Set
  `manage_subids => false` to let an operator or another module own the ranges.
  **Stable subuids are required** — if they are purged, the rootless container
  falls back to the overflow uid and cannot write its volumes.
- The container image runs as a non-root user (uid 10001). Under rootless podman
  that internal id is remapped to a host subordinate id, so the bind-mounted
  log/audit volumes are owned by a companion `<user>-pod` account at the mapped
  id (`subid_start + uid - 1`), not by the login user. (`keep-id`, which would
  let the container keep the login uid, is broken on podman 5.x + EL10/UEK —
  crun `ping_group_range`/`devpts` errors — so the mapped-owner approach is used
  instead.) Under docker there is no remap and the volumes are login-user owned.

## Development

Validate and test with [Regent](https://github.com/felipe-quintella/regent)
(never `pdk`):

```sh
regent validate
regent test
```

Author: Felipe Quintella
License: Apache-2.0
