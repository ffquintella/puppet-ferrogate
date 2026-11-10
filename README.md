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
/srv/application-data/ferrogate[/<app_environment>]/raft    # CMIS raft store (allowlists, proposals, SVIDs)
/srv/application-data/ferrogate[/<app_environment>]/issuer  # CMIS issuer signing key
/srv/application-data/ferrogate[/<app_environment>]/admin   # CMIS admin keys (secrets.key, audit-pseudonym.key)
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

## High Availability (CMIS Raft cluster)

CMIS keeps every durable store — issued SVIDs, host allowlists, pending
allowlist proposals — in a [hiqlite](https://github.com/sebadob/hiqlite)-backed
Raft state machine under the `raft` volume. By default the module runs a
**single-node** cluster: the node is its own only peer, elects itself leader,
and never looks for others — state still persists across restarts and image
upgrades. Nothing extra is configured for this; it is the `cmis_cluster_peers`
empty default.

To run a **multi-node** cluster (F05 HA), list every peer — including this node
— in `cmis_cluster_peers`, keyed by Raft node id, and set `cmis_node_id` to this
node's id. The `raft_addr`/`api_addr` are the addresses peers *dial*, so they
must be routable from the other nodes (hostnames or stable IPs, never loopback).
A multi-node cluster also requires the fleet-wide shared secrets
`cmis_raft_secret` / `cmis_api_secret` (≥ 16 characters, identical on every
node). The module renders `CMIS_CLUSTER_PEERS` / `CMIS_NODE_ID` / the secrets
into `cmis.env`, binds the Raft/management transports on `cmis_raft_listen`
(`0.0.0.0` by default, ports `cmis_raft_port` 9601 / `cmis_api_port` 9602), and
turns on the encrypted inter-node transport (`cmis_peer_tls`, on by default).

Requires the CMIS image **≥ 0.18.11** (the version that binds a routable
interface and adds the TLS peer transport). Pin it via `image_tag`.

### Inter-node TLS trust (peer CA)

hiqlite's split-brain / cluster-metrics client validates each peer's certificate
with **rustls' platform verifier** — the OS trust store *inside the CMIS
container* — not the shared-secret handshake the Raft transport uses. A bare
self-signed `CMIS_PEER_TLS=1` certificate therefore fails that probe with
`UnknownIssuer` (`failed to verify TLS certificate: invalid peer certificate:
UnknownIssuer`), leaving the split-brain safety check blind even while Raft keeps
replicating.

So for a multi-node cluster the module, by default (`cmis_peer_ca_manage`),
issues this node's inter-node **leaf certificate from a CA** and points the
container's verifier at that CA via `SSL_CERT_FILE`. The CA cert and leaf are
written to a host `peer-tls/` directory under the config root and bind-mounted
into the container at `/etc/ferrogate/peer-tls`; the CA *private* key stays
host-only and is never mounted. See `ferrogate::peer_ca`.

For this to work across hosts, **every node must trust the CA that signed every
peer's leaf** — so a real multi-node fleet shares **one** CA: supply the same
`cmis_peer_ca_cert` / `cmis_peer_ca_key` (the key via eyaml) on every node.

```puppet
class { 'ferrogate':
  image_tag          => '0.18.11',
  cmis_cluster_peers => { 1 => { ... }, 2 => { ... }, 3 => { ... } },
  cmis_node_id       => 2,
  cmis_raft_secret   => $raft_secret,
  cmis_api_secret    => $api_secret,
  cmis_peer_ca_cert  => $peer_ca_cert,   # SAME CA on every node ⇒ mutual trust
  cmis_peer_ca_key   => $peer_ca_key,    # eyaml; written 0600, host-only
  # cmis_peer_cert_san => ['IP:10.0.0.2'],  # if peers dial an address ≠ the FQDN
}
```

If `cmis_peer_ca_cert`/`_key` are omitted the module **generates a local CA** —
fine for a single-node cluster (the node dials itself), but for multiple hosts
you must distribute the generated `ca.crt`/`peer-ca.key` to every peer, so
supplying a shared CA is strongly preferred. The leaf's `subjectAltName` defaults
to the node FQDN; add the dialed address with `cmis_peer_cert_san` when it
differs (rustls matches the dialed name against the SAN). The peer-CA path
requires **OpenSSL ≥ 3.0** on the host. To opt out and keep the bare self-signed
transport, set `cmis_peer_ca_manage => false`; to bring your own leaf entirely,
set `cmis_peer_tls_cert` / `cmis_peer_tls_key` (you then own trust distribution).

> **Trust scope:** `SSL_CERT_FILE` makes the container's platform verifier trust
> *only* this CA. That is correct for the inter-node mesh (CMIS does no outbound
> public-CA TLS, and the F01 listener is authenticated by SPKI pin, not a CA
> chain). If you need the container to trust public CAs as well, supply a bundle
> that concatenates the system roots with this CA.

```puppet
# node 2 of a three-node cluster
class { 'ferrogate':
  image_tag          => '0.18.11',
  cmis_cluster_peers => {
    1 => { 'raft_addr' => 'cmis1.example.com:9601', 'api_addr' => 'cmis1.example.com:9602' },
    2 => { 'raft_addr' => 'cmis2.example.com:9601', 'api_addr' => 'cmis2.example.com:9602' },
    3 => { 'raft_addr' => 'cmis3.example.com:9601', 'api_addr' => 'cmis3.example.com:9602' },
  },
  cmis_node_id     => 2,
  cmis_raft_secret => $raft_secret,  # ≥16 chars, shared across the fleet
  cmis_api_secret  => $api_secret,
  # cmis_peer_tls   => true,         # default; set false only on a trusted LAN
}
```

> **Networking:** CMIS binds its Raft/API transports on `cmis_raft_listen`
> (`0.0.0.0`) and hiqlite's leader dials its own advertised address. Rootless
> `pasta` cannot hairpin a published port back into its own container, so the
> module runs the multi-node CMIS container with **host networking**
> (automatic) — the transports bind directly on the host. Leave `cmis_peer_tls`
> on unless every peer shares a trusted private network. Keep peers within
> ~80 ms of each other — Raft commit latency is on the SVID issuance path. Use
> an odd peer count (3 or 5) so a quorum survives one (or two) node losses.

> **Raft timing:** on a slow or lossy peer link a healthy two-node cluster can
> report `not enough for a quorum`. Widen the timing with
> `cmis_raft_heartbeat_ms`, `cmis_raft_election_min_ms` and
> `cmis_raft_election_max_ms` (CMIS defaults 500 / 1500 / 3000 ms), identical on
> every node, e.g. `2000 / 6000 / 12000`. The election minimum must be at least
> 3 x the heartbeat; values below the defaults need
> `cmis_raft_allow_aggressive_timeouts => true`. Unset means no change. A third
> peer is the real fix for fault tolerance.

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

Instead of shipping the allowlist body out-of-band, let MIA pull this host's
allowlist from CMIS on every start (keyed by EK-UUID) and write it to
`allowlist_path`, verified against `allowlist_key`:

```puppet
class { 'ferrogate::mia':
  cmis_endpoint          => 'https://cmis.example.com:8443',
  cmis_spki_pin          => '5f2e...c4',
  allowlist_path         => '/var/lib/ferrogate/allowlist.cbor',
  allowlist_key          => '/var/lib/ferrogate/allowlist.pub',
  allowlist_fetch        => true,
  allowlist_max_age_secs => 86400,
}
```

The daemon writes the fetched body to `allowlist_path` on start, so its parent
directory must exist. `manage_allowlist_dir` (default `true`) ensures it — a
no-op when the path is unset or already inside a managed `config_dir`, so the
`/var/lib/ferrogate` above is created for you. The module never writes the
allowlist body or the `allowlist_key`; provision the key out of band (MIA
verifies the fetched body against it). Set `manage_allowlist_dir => false` if
the package or another module owns the directory.

On the **A2 bootstrap** path a host proposes itself to CMIS for allowlisting;
add `allowlist_propose => true` **only** for bootstrap and remove it once the
host is approved:

```puppet
class { 'ferrogate::mia':
  cmis_endpoint     => 'https://cmis.example.com:8443',
  cmis_spki_pin     => '5f2e...c4',
  allowlist_path    => '/var/lib/ferrogate/allowlist.cbor',
  allowlist_key     => '/var/lib/ferrogate/allowlist.pub',
  allowlist_fetch   => true,
  allowlist_propose => true,   # bootstrap only — drop after approval
}
```

The class installs the package, creates the `_ferrogate` privilege-drop account
the daemon needs, renders **both** config surfaces, and enables/starts the `mia`
service:

- `<config_dir>/mia.env` — the systemd `EnvironmentFile` the **service** loads.
  It carries everything, including the hardening/runtime toggles that have no
  TOML equivalent (`seccomp`, `require_ima`, `run_as_*`, `extra_env`).
- `<config_dir>/mia.toml` — the config file `mia` reads **directly**. Interactive
  commands such as `mia test` do *not* inherit the service's `EnvironmentFile`,
  so without this file they read the empty packaged template and fail even when
  the service is healthy. Rendered from the same parameters (set
  `manage_toml => false` to skip it).

MIA's precedence is `defaults < mia.toml < FERROGATE_* env`, so the two files
stay consistent and the env file still wins for the running daemon.

### Platform support

`ferrogate::mia` is **cross-platform**:

- **RedHat / Debian families** — installs the `ferrogate-mia` RPM/DEB, writes a
  systemd `EnvironmentFile` at `/etc/ferrogate/mia.env`, and manages the `mia`
  unit via `systemd`.
- **Windows** — installs the `ferrogate-mia` Chocolatey package
  (`provider => chocolatey`), writes the config file to
  `C:/ProgramData/ferrogate/mia.env`, and manages the bundled Windows service.
  The hardening-profile knobs (`seccomp`, `ima_log`, `require_ima`,
  `skip_hardening`, `run_as_uid`/`run_as_gid`) and the Unix-socket helper default
  are Linux-only; on Windows the helper API uses a named pipe (set `helper_socket`
  explicitly if you need it). Requires the
  [`puppetlabs/chocolatey`](https://forge.puppet.com/puppetlabs/chocolatey)
  module on the node (it supplies the `chocolatey` provider and
  `chocolateysource` type).

By default (`manage_repo => false`) the package is assumed reachable through the
node's existing repositories / Chocolatey sources, and the module actively
**removes** any `ferrogate-mia` repo it added on a previous run (setting the
`yumrepo` / apt source / Chocolatey source to `ensure => absent`, ordered before
the package). That way a stale or broken repo URL — for example a NuGet feed
baseurl mistakenly applied to a RedHat host, which makes `dnf` 404 on every
run — stops breaking package resolution, and the package falls back to a
pre-existing repository. The removal is a no-op on a node that never had one.

To add a custom `ferrogate-mia` repository, set `manage_repo => true` and
`repo_baseurl` — a `yumrepo` on the RedHat family, an apt source list on the
Debian family, or a `chocolateysource` (custom NuGet feed) on Windows, ordered
before the package:

```puppet
# RedHat / Debian — RPM/DEB repository
class { 'ferrogate::mia':
  cmis_endpoint => 'https://cmis.example.com:8443',
  cmis_spki_pin => '5f2e...c4',
  manage_repo   => true,
  repo_baseurl  => 'https://repo.example.com/ferrogate/el9/x86_64',
  repo_gpgkey   => 'https://repo.example.com/ferrogate/RPM-GPG-KEY',
}

# Windows — private Chocolatey source (NuGet feed)
class { 'ferrogate::mia':
  cmis_endpoint => 'https://cmis.example.com:8443',
  cmis_spki_pin => '5f2e...c4',
  manage_repo   => true,
  repo_baseurl  => 'https://nuget.example.com/ferrogate/index.json',
  repo_user     => 'svc-puppet',   # optional, for an authenticated feed
  repo_password => 'feed-secret',  # optional (drive from Hiera/eyaml)
}
```

| Parameter (key ones)   | Default                     | Description                                              |
| ---------------------- | --------------------------- | -------------------------------------------------------- |
| `package_name`         | `'ferrogate-mia'`           | MIA package (Chocolatey id on Windows).                  |
| `package_ensure`       | `'installed'`               | `ensure` for the package.                               |
| `manage_repo`          | `false`                     | `true`: add a custom `ferrogate-mia` repo (needs `repo_baseurl`); `false`: remove any repo the module added, use existing repos.|
| `repo_baseurl`         | `undef`                     | Repo URL (yum `baseurl` / apt `deb` URI / Choco source).|
| `repo_gpgkey`          | `undef`                     | GPG key (RedHat URL/path; Debian `signed-by` keyring).  |
| `repo_user` / `repo_password` | `undef`              | Windows — auth for the custom Chocolatey source/feed.   |
| `repo_priority`        | `undef`                     | Windows — priority of the custom Chocolatey source.     |
| `config_dir`           | OS default                  | `/etc/ferrogate` (Linux) / `C:/ProgramData/ferrogate` (Windows). |
| `manage_toml`          | `true`                      | Also render `<config_dir>/mia.toml` so `mia test` works.|
| `manage_allowlist_dir` | `true`                      | Ensure the directory of `allowlist_path` exists (needed for `allowlist_fetch`). |
| `manage_user`          | `true`                      | Create the `_ferrogate` privilege-drop account (Linux). |
| `cmis_endpoint`        | `undef`                     | `FERROGATE_CMIS_ENDPOINT` — the CMIS server URL.        |
| `cmis_spki_pin`        | `undef`                     | `FERROGATE_CMIS_SPKI_PIN` — accepted SPKI pin (SHA-384).|
| `helper_socket`        | `'/run/ferrogate/mia.sock'` | Helper-API socket; its presence enables the helper API. |
| `allowlist_path`       | `undef`                     | Signed CBOR caller allowlist (requires `allowlist_key`).|
| `allowlist_key`        | `undef`                     | Enrollment public key that verifies the allowlist.      |
| `allowlist_max_age_secs` | `undef`                   | Max accepted allowlist age (seconds).                   |
| `allowlist_fetch`      | `undef`                     | Pull this host's allowlist from CMIS each start, by EK-UUID (needs `allowlist_path`). |
| `allowlist_propose`    | `undef`                     | A2 bootstrap only — propose this host to CMIS; remove after approval. |
| `allowlist_propose_interval_secs` | `undef`          | Re-propose interval (seconds); needs `allowlist_propose => true`. |
| `attest_backend`       | `undef`                     | `FERROGATE_ATTEST_BACKEND`: `host-key` (default) / `virtual-tpm` (dev/test). |
| `seccomp`              | `undef`                     | `FERROGATE_SECCOMP`: `enforce`/`audit`/`off`.           |
| `skip_hardening`       | `false`                     | Set `FERROGATE_SKIP_HARDENING=1` (dev only).            |
| `rust_log`             | `'info'`                    | `RUST_LOG` tracing filter.                              |

#### Attestation backend

`attest_backend` selects how the agent obtains its host SVID. Left `undef` the
module writes nothing and the agent takes its own default, `host-key` — the
TPM-less production profile (a hardware fingerprint plus a machine signing key)
that works on every supported platform:

```puppet
class { 'ferrogate::mia':
  cmis_endpoint  => 'https://cmis.example.com:8443',
  cmis_spki_pin  => '5f2e...c4',
  attest_backend => 'virtual-tpm',   # dev/test only — see the warning below
}
```

> **`virtual-tpm` is insecure and for dev/test only.** It runs the full TPM
> attestation handshake against an **in-process software TPM** with no hardware
> root of trust — there is *no* `swtpm` (or other emulator) to install; the
> virtual TPM lives inside the `mia` process. It works only when `mia` was built
> with the off-by-default `virtual-tpm` cargo feature (a stock release binary
> refuses it and fails closed) and only against a CMIS configured to trust the
> synthetic EK root and PCR digest the agent logs at startup. Never use it in
> production.

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
| `cmis_allowlist_proposals` | `'bootstrap'` | `CMIS_ALLOWLIST_PROPOSALS` — host-driven `ProposeAllowlist` policy: `off`/`bootstrap`/`always`. |
| `cmis_svid_ttl_secs`  | `undef`          | `CMIS_SVID_TTL_SECS` (CMIS ≥ 0.19.12) — issued-SVID lifetime in seconds. Unset = binary default (30 d). Range `[96 h, 30 d]`. |
| `cmis_allowlist_ttl_secs` | `undef`      | `CMIS_ALLOWLIST_TTL_SECS` (CMIS ≥ 0.19.12) — signed-allowlist validity in seconds. Unset = binary default (96 h). Range `[96 h, 30 d]`; keep ≤ MIA's `allowlist.max_age_secs`. |
| `cmis_admin_pepper_file` | `undef` | `CMIS_ADMIN_PEPPER_FILE` — in-container path of the admin password pepper. Unset = no pepper. Identical on every node; set before enrolling the first admin. |
| `cmis_admin_password_blocklist_file` | `undef` | `CMIS_ADMIN_PASSWORD_BLOCKLIST_FILE` — in-container path of an extra admin password blocklist. Unset = embedded list only. |
| `cmis_admin_listen` | `undef` | `CMIS_ADMIN_LISTEN` — admin listener address (in-container). Unset = CMIS default `127.0.0.1:8444` (host-local only). The `Admin` service is never served on the main listener, so remote admin clients need this set (e.g. `'0.0.0.0:8444'`) **and** a firewall limiting the port to the management network. |
| `cmis_admin_port` | `8444` | Port published for the admin listener on single-node deployments, only when `cmis_admin_listen` is set. Must match `cmis_admin_listen`. Ignored on multi-node (host networking). |
| `cmis_cluster_peers`  | `{}`             | CMIS HA Raft peer set (`id => {raft_addr,api_addr}`). Empty = single-node. See [High Availability](#high-availability-cmis-raft-cluster). |
| `cmis_node_id`        | `undef`          | This node's id within `cmis_cluster_peers` (required when multi-node). |
| `cmis_raft_port` / `cmis_api_port` | `9601` / `9602` | Raft + management-API transport ports (single-node `*_ADDR`; published when multi-node). |
| `cmis_raft_secret` / `cmis_api_secret` | `undef` | Fleet-wide shared secrets (≥16 chars). Required for a multi-node cluster. |
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

- The **container server** (`ferrogate` class) is Linux-only — RedHat and Debian
  families (rootless podman/Quadlet, SELinux, systemd). The standalone
  [`ferrogate::mia`](#mia-host-agent-ferrogatemia) host agent additionally
  supports **Windows** via a Chocolatey `.nupkg`. See `metadata.json`.
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
