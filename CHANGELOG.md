# Changelog

All notable changes to this module are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this module
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.13.0] - 2026-11-10

### Added
- **`cmis_admin_listen`** → `CMIS_ADMIN_LISTEN` (default `undef` = unset, so the
  admin listener keeps CMIS's `127.0.0.1:8444` and nothing changes on upgrade).
  The `Admin` gRPC service (login, accounts, sessions, enrollment) is served
  only on that listener — on the main listener (8443) it answers
  `UNIMPLEMENTED admin_listener_only` — so remote admin clients (CLI, tray admin
  app) could not reach it. Set it (e.g. `'0.0.0.0:8444'`) to expose it, and
  restrict the port with a host firewall.
- **`cmis_admin_port`** (default `8444`): the port published for the admin
  listener on a single-node (rootless `pasta`) deployment, only when
  `cmis_admin_listen` is set. Multi-node clusters use host networking and need no
  published port.

### Upgrade note
- Setting `cmis_admin_listen` changes `cmis.env` (and, single-node, the Quadlet
  unit), so the service restarts on the node that receives the change.

## [0.12.2] - 2026-11-04

### Fixed
- **Perpetual SELinux "corrective" changes on every agent run.** The
  container-mounted directories and TLS/peer-TLS files are relabelled by the
  container runtime (`container_file_t` with a per-container MCS range via
  `:Z`), but Puppet reset them to the policy default (`var_t`, `s0`) each run.
  These resources now set `selinux_ignore_defaults => true`, so Puppet leaves
  their SELinux attributes alone.

## [0.12.1] - 2026-11-04

### Fixed
- **Rootless podman: a changed Quadlet `.container` file now restarts the
  running service.** The module only ran `systemctl --user start`, guarded by
  `is-active`, which is a no-op on a running unit — so changes (new volumes,
  image tag) were written but never applied until someone restarted by hand. A
  `refreshonly` restart exec, subscribed to the unit file, now handles it. Note
  this restarts the service on every node that receives a unit change.

## [0.12.0] - 2026-11-04

### Added
- **Persistent admin state volume.** CMIS now mounts
  `/srv/application-data/ferrogate[/<env>]/admin` at `/var/lib/ferrogate/admin`
  (directory managed, container-mapped owner, mode `0750`). Previously the admin
  `secrets.key` and `audit-pseudonym.key` lived in the container's ephemeral
  layer, so every container recreate generated new keys; once the cluster had
  admin state the admin subsystem then refused to start ("admin key files differ
  from the ones this cluster was set up with") and the admin listener (8444)
  never came up. The module does **not** write the key files: they must be
  identical on every node of a multi-node cluster and are provisioned out of
  band.
- **`cmis_admin_pepper_file`** → `CMIS_ADMIN_PEPPER_FILE` and
  **`cmis_admin_password_blocklist_file`** → `CMIS_ADMIN_PASSWORD_BLOCKLIST_FILE`
  (both in-container paths, default `undef` = unset).

### Upgrade note
- Adding the volume changes the Quadlet unit, so Puppet recreates the container.
  On a node that already has admin state, **copy the live key files out of the
  running container into the new host `admin/` directory first**
  (`podman cp ferrogate-cmis:/var/lib/ferrogate/admin/. <admin_dir>/`, mode
  `0400`/`0600`, container-mapped owner) — otherwise an empty directory is
  mounted and new keys are generated.

## [0.11.0] - 2026-07-07

### Added
- **`manage_allowlist_dir` parameter on `ferrogate::mia`** (default `true`) to
  ensure the directory holding `allowlist_path` exists. This completes the
  `allowlist_fetch` path added in 0.10.0: the daemon writes the fetched signed
  body to `allowlist_path` on start and fails if the parent directory is
  missing, and the packaged default (`/var/lib/ferrogate`) lives outside
  `config_dir`. The directory is created with the same owner/group/mode as
  `config_dir`, ordered after the package and before the service. It is a no-op
  when `allowlist_path` is unset or already resolves inside a managed
  `config_dir` (no duplicate resource). The module still never writes the
  allowlist body or the `allowlist_key` — provision the key out of band; MIA
  verifies the fetched body against it. Set `false` when the package or another
  module owns the directory.

## [0.10.0] - 2026-07-07

### Added
- **Allowlist fetch/propose parameters on `ferrogate::mia`.** Three new optional
  parameters manage the `[allowlist]` fetch and A2-bootstrap keys, rendered into
  both config surfaces from the same values:
  - `allowlist_fetch` → `FERROGATE_ALLOWLIST_FETCH` / `[allowlist] fetch`: when
    `true`, MIA pulls this host's allowlist from CMIS on every start (keyed by
    EK-UUID) and writes the signed body to `allowlist_path`, verified against
    `allowlist_key`.
  - `allowlist_propose` → `FERROGATE_ALLOWLIST_PROPOSE` / `[allowlist] propose`:
    the A2 bootstrap path where a host proposes itself to CMIS for allowlisting.
    Enable **only** for bootstrap and remove once the host is approved.
  - `allowlist_propose_interval_secs` →
    `FERROGATE_ALLOWLIST_PROPOSE_INTERVAL_SECS` /
    `[allowlist] propose_interval_secs`: re-propose cadence while awaiting
    approval; only meaningful with `allowlist_propose => true`.

  All three default to `undef` (emit nothing, take the agent default). Compile-time
  guards require `allowlist_path` for any of them and require `allowlist_propose`
  when an interval is set. Booleans render as `1`/`0` in `mia.env` and as native
  TOML booleans in `mia.toml`.

## [0.9.0] - 2026-07-06

### Added
- **`attest_backend` parameter on `ferrogate::mia`** to select MIA's host-SVID
  attestation backend. Maps to `FERROGATE_ATTEST_BACKEND` in `mia.env` and
  `[attestation] backend` in `mia.toml`. Left `undef` (the default) the module
  emits nothing and the agent takes its own default, `host-key` — the TPM-less
  production profile that works on every platform. Setting `'virtual-tpm'`
  selects MIA's **in-process software virtual TPM**: it runs the full TPM
  attestation handshake with no hardware root of trust and is **insecure,
  dev/test only**. There is no `swtpm` (or other) emulator to install — the
  virtual TPM lives inside the `mia` binary — but it requires a `mia` build
  compiled with the off-by-default `virtual-tpm` cargo feature (a stock release
  binary refuses it and fails closed) and a CMIS configured to trust the
  synthetic EK root and PCR digest the agent logs at startup. Rendered into both
  config surfaces from the same parameter.

## [0.8.0] - 2026-07-06

### Added
- **`ferrogate::mia` now renders `<config_dir>/mia.toml`** (the config file the
  agent reads directly), in addition to the existing systemd `EnvironmentFile`
  (`mia.env`). Interactive commands such as `mia test` do **not** inherit the
  service's `EnvironmentFile`, so previously they read the empty packaged TOML
  template and failed (`neither cmis.endpoint nor cmis.srv is set`,
  `helper.socket is not configured`) even when the running service was correctly
  configured. Both files are rendered from the same parameters; MIA's precedence
  (`defaults < mia.toml < FERROGATE_* env`) keeps them consistent. Only
  agent-honored keys are emitted (an unknown key makes MIA fail loudly at
  startup); the hardening/runtime toggles with no TOML equivalent stay in
  `mia.env`. New `manage_toml` parameter (default `true`) to opt out.
- **`ferrogate::mia` now creates the `_ferrogate` privilege-drop account** the
  daemon requires. `mia` starts as root and drops to `_ferrogate`; the package
  ships no scriptlet to create it, so on a stock host the daemon exited with
  `service user _ferrogate not found` and systemd crash-looped it, never binding
  the helper socket. New `manage_user` (default `true`), `user_name`
  (default `_ferrogate`), and `user_shell` (default `/sbin/nologin`) parameters;
  Linux only (Windows runs the service as `LocalSystem`).

## [0.7.1] - 2026-07-06

### Added
- **`cmis_srv` parameter on `ferrogate::mia`** for high-availability CMIS
  discovery. Set it to a DNS SRV record (e.g. `_cmis._tcp.example.com`) and the
  agent resolves it, prefers records by RFC 2782 priority/weight, dials the best
  live node over hybrid-PQC TLS, and fails over automatically — an alternative
  to the single `cmis_endpoint` URL. The rendered config gains a
  `FERROGATE_CMIS_SRV` line. `cmis_spki_pin` authenticates every node behind the
  record.
- Compile-time guard: `cmis_endpoint` and `cmis_srv` are mutually exclusive and
  setting both now fails with a clear error rather than letting the daemon
  reject it at runtime.

## [0.7.0] - 2026-06-30

### Added
- **Windows support for the standalone MIA host agent (`ferrogate::mia`).** The
  class is now cross-platform. On Windows it installs the `ferrogate-mia`
  Chocolatey package (`provider => chocolatey`), writes its config file to
  `C:/ProgramData/ferrogate/mia.env`, and manages the bundled service via the
  native `windows` provider. The existing RedHat/Debian behaviour (RPM/DEB +
  systemd `EnvironmentFile`) is unchanged.
  - `config_dir` now defaults to `undef`, resolving to `/etc/ferrogate` on Linux
    and `C:/ProgramData/ferrogate` on Windows (explicit values still honoured).
  - `manage_repo => true` registers a **custom Chocolatey source** (private
    NuGet feed) on Windows — the package's `repo_baseurl` becomes the source
    `location`, with new `repo_user` / `repo_password` / `repo_priority`
    parameters for authenticated feeds. RedHat (`yumrepo`) and Debian (apt
    source list) behaviour is unchanged.
  - The hardening-profile knobs (`seccomp`, `ima_log`, `require_ima`,
    `skip_hardening`, `run_as_uid`/`run_as_gid`) and the Unix-socket
    `helper_socket` default are Linux-only; the inapplicable Unix-socket default
    is dropped on Windows.

### Dependencies
- Added `puppetlabs/chocolatey` (`>= 5.0.0 < 9.0.0`) — supplies the `chocolatey`
  package provider and the `chocolateysource` type used on Windows.

### Compatibility
- `metadata.json` `operatingsystem_support` now lists Windows (2019, 2022, 10,
  11) for the MIA host agent.

## [0.6.2] - 2026-06-22

### Added
- **Operator-tunable CMIS signature lifetimes (FerroGate ≥ 0.19.12).** CMIS
  0.19.12 made the SVID and caller-allowlist TTLs configurable (previously
  hardcoded), reading `CMIS_SVID_TTL_SECS` (default 30 days) and
  `CMIS_ALLOWLIST_TTL_SECS` (default 96 h) and clamping each to a `[96 h, 30 d]`
  window. The module now exposes both as first-class parameters:
  - `cmis_svid_ttl_secs` — `CMIS_SVID_TTL_SECS`, the lifetime of issued SVIDs.
  - `cmis_allowlist_ttl_secs` — `CMIS_ALLOWLIST_TTL_SECS`, the validity window
    of signed caller-allowlists.

  Both default to `undef`, leaving the var unset so the binary keeps its
  built-in default — existing deployments are unaffected. The parameter type
  (`Integer[345600, 2592000]`) enforces the same `[96 h, 30 d]` range at catalog
  compile, so an out-of-range value fails fast instead of being silently
  clamped. **`cmis_allowlist_ttl_secs` must not exceed the MIA's
  `allowlist.max_age_secs`** (`FERROGATE_ALLOWLIST_MAX_AGE_SECS`, also 96 h by
  default), or a freshly signed list is rejected by the consumer as stale —
  raise both together if you lengthen it.

## [0.6.1] - 2026-06-15

### Added
- **`cmis_trust_domain` — manage `CMIS_TRUST_DOMAIN` as a first-class
  parameter.** CMIS stamps a SPIFFE trust domain into every SVID and allowlist
  it issues (the binary reads `CMIS_TRUST_DOMAIN`, falling back to its built-in
  `ferrogate.dev`). Previously this could only be set through the generic
  `extra_env` escape hatch; it now has its own parameter. `undef` (the default)
  leaves the var unset so the binary keeps its default — existing deployments
  are unaffected. **Must stay constant for a given issuer seed**: set it once at
  bring-up (e.g. `'ferrogate.prod'`) and treat it as immutable, since changing
  it re-scopes every issued identity.

## [0.5.0] - 2026-06-11

### Added
- **CMIS High Availability (F05) — manage the Raft cluster parameters.** CMIS
  keeps every durable store (issued SVIDs, host allowlists, pending allowlist
  proposals) in a hiqlite-backed Raft state machine. The module now exposes the
  full HA surface:
  - `cmis_cluster_peers` — the Raft peer set, keyed by node id
    (`id => { 'raft_addr' => 'host:port', 'api_addr' => 'host:port' }`). Empty
    (the default) renders a self-bootstrapping **single-node** cluster
    (`CMIS_RAFT_ADDR` / `CMIS_API_ADDR` on loopback); a non-empty hash renders
    `CMIS_CLUSTER_PEERS` (`id=raft_addr,api_addr` joined by `;`) for a
    **multi-node** cluster.
  - `cmis_node_id` — which peer entry is this node (`CMIS_NODE_ID`); required,
    and validated to be a key of `cmis_cluster_peers`, when multi-node.
  - `cmis_raft_port` / `cmis_api_port` (default `9601` / `9602`) — the Raft and
    management-API transport ports, published on the host for a multi-node
    cluster so peers can reach this node.
  - `cmis_raft_secret` / `cmis_api_secret` — the fleet-wide shared secrets
    (`CMIS_RAFT_SECRET` / `CMIS_API_SECRET`), typed `String[16]` to enforce
    hiqlite's ≥16-char minimum and **required** for a multi-node cluster.

  A single-node cluster publishes only the gRPC port, exactly as before; the
  defaults are unchanged, so existing deployments keep running single-node.
  See the new "High Availability" section in the README for the network-
  reachability caveat (upstream CMIS binds the peer transports to container
  loopback today).

## [0.4.3] - 2026-06-11

### Fixed
- **CMIS TLS SPKI pin now survives certificate re-issue and upgrades.** The
  self-signed cert path generated the P-384 private key and the certificate in
  a single `openssl req -newkey` exec keyed on the cert file, so re-issuing the
  cert (removing `cmis.crt`, or the tls dir being recreated during an upgrade)
  silently generated a **new key** — changing the SHA-384 SPKI pin and breaking
  every pinned client (MIAs, BastionVault `cmis_grpc`) at once. Key generation
  (`ferrogate-tls-genkey`, keyed on `cmis.key`) is now a separate idempotent
  step from cert issuance (`ferrogate-tls-generate`, issues from the existing
  key): removing only the cert re-issues with the same key and an unchanged
  pin. Rotating the pin is now a deliberate act — remove both the key and the
  cert, re-run Puppet, and re-pin every client. Completes what 0.4.1 did for
  the raft store and issuer key.

## [0.4.2] - 2026-06-10

### Added
- **`cmis_allowlist_proposals` — configure CMIS host-driven allowlist
  proposals, on by default.** FerroGate's MIA proposes the local callers it
  observes back to CMIS over the `ProposeAllowlist` RPC so a freshly installed
  host can bootstrap its own allowlist. The module now emits
  `CMIS_ALLOWLIST_PROPOSALS` into `cmis.env`, exposed as the
  `Enum['off','bootstrap','always']` parameter `cmis_allowlist_proposals`:
  - `'off'` — never auto-adopt; every proposal queues for operator review.
  - `'bootstrap'` (**default**) — auto-adopt only when the host has no allowlist
    yet (first-use TOFU); any change to an existing allowlist queues for review.
  - `'always'` — auto-adopt every accepted proposal, including changes.

  Every proposal is still verified (SVID + signature) regardless of policy;
  this only governs whether an accepted proposal becomes the live allowlist on
  its own. The previous behaviour left the variable unset, which CMIS already
  treats as `bootstrap`; the module now sets it explicitly.

## [0.4.1] - 2026-06-10

### Fixed
- **CMIS lost all allowlists, proposals, issued SVIDs and its issuer signing
  key on every image upgrade.** FerroGate 0.18.x persists that state under
  `/var/lib/ferrogate/raft` (`CMIS_RAFT_DIR` default) and
  `/var/lib/ferrogate/issuer` (`CMIS_ISSUER_KEY` default), but the module never
  bind-mounted those paths, so the raft store landed on the container's
  ephemeral layer and the issuer key in an anonymous podman volume — both
  discarded whenever the container is recreated (e.g. on every image bump).
  The module now manages `data_dir/raft` and `data_dir/issuer` (owned by the
  container-mapped id, like the audit dir) and bind-mounts them into the CMIS
  container.

## [0.4.0] - 2026-06-08

### Added
- **`ferrogate::mia` — install and configure the MIA host agent from its OS
  package.** A new standalone class that deploys the Machine Identity Agent the
  way FerroGate ships it: as the native `ferrogate-mia` package (static
  `/usr/bin/mia` binary + `mia` systemd unit), *not* in a container. It can be
  declared on any host on its own, with no dependency on the `ferrogate` server
  class, `baseapp`, a container runtime, or the dedicated service user.
  - Installs the package, manages `/etc/ferrogate`, renders the systemd
    `EnvironmentFile` at `/etc/ferrogate/mia.env`, and enables/starts the `mia`
    service (restarting it when the env file changes).
  - Configures the agent through `FERROGATE_*` variables: CMIS endpoint and
    SPKI pin (`cmis_endpoint` / `cmis_spki_pin`), the helper-API socket
    (`helper_socket` / `helper_socket_mode`), the signed caller allowlist
    (`allowlist_path` / `allowlist_key` / `allowlist_max_age_secs`), attestation
    (`ima_log`), hardening toggles (`seccomp`, `require_ima`, `skip_hardening`,
    `run_as_uid` / `run_as_gid`), `rust_log`, and free-form `extra_env`.
  - Fails fast when `allowlist_path` is set without `allowlist_key` (the agent
    rejects an unverifiable allowlist).
  - Optional custom package repository, **off by default** (`manage_repo`,
    `repo_baseurl`, `repo_descr`, `repo_gpgcheck`, `repo_gpgkey`, `repo_release`,
    `repo_components`): when enabled, declares a `yumrepo` on the RedHat family
    or an apt source list on the Debian family, ordered before the package.
  - This is distinct from the container-based `mia_enable` switch on the main
    `ferrogate` class, which remains for images that bundle the `mia` binary.

### Changed
- **Subordinate UID/GID management moved to baseapp (breaking).** The
  `subid_management` parameter (`'usermod'` / `'podman'` / `'none'`) is removed
  and replaced by a single boolean `manage_subids` (default `true`). FerroGate
  now registers the service user's range through `baseapp::subid`, and baseapp
  owns `/etc/subuid` / `/etc/subgid` as concat targets — so ferrogate and other
  rootless apps (e.g. bastionvault) share one consistently-managed pair of files
  instead of fighting over them (the previous `usermod` default appended outside
  any concat manager and was purged each run on nodes where `puppet/podman`
  managed the files). **Requires `baseapp` >= 0.3.0.** If `puppet/podman` is also
  on the node, leave its `manage_subuid => false` (the default) so it does not
  declare a competing `Concat['/etc/subuid']`.
  - Migration: remove any `ferrogate::subid_management` data. Default nodes need
    no change; nodes that set `subid_management => 'none'` should set
    `manage_subids => false`.

## [0.3.6] - 2026-06-03

### Changed
- The in-container operator CLI now reaches a TLS-on CMIS over the F01
  hybrid-PQC transport, auto-deriving the SPKI pin from the mounted server
  certificate (`/etc/ferrogate/tls/cmis.crt`). No module behavior changed — the
  wrapper already uses `https://` and mounts the cert at the path the CLI
  defaults to. This capability requires the **ferrogate CLI ≥ 0.15.0** (the F01
  CLI release); older plaintext-only CLIs still need `cmis_tls_enable => false`.
  README updated to drop the earlier "CLI is plaintext-only" caveat.

## [0.3.5] - 2026-06-03

### Added
- **Hybrid-PQC TLS for the CMIS listener (FerroGate F01).** The module now
  configures, and optionally creates, the TLS material that CMIS terminates
  (TLS 1.3, `X25519MLKEM768`-only; trust is by SPKI pin, not a CA chain).
  - New `cmis_tls_enable` parameter (**default `true`**). When on, the module
    sets `CMIS_TLS_CERT` / `CMIS_TLS_KEY` for the container and ensures a
    certificate exists; when off, CMIS runs its plaintext bring-up server.
  - Supply your own cert with `cmis_tls_cert` / `cmis_tls_key` (PEM strings), or
    let the module generate a self-signed P-384 certificate (`cmis_tls_manage_cert`,
    default `true`; `cmis_tls_cert_cn`, `cmis_tls_cert_days`). Requires `openssl`
    on the host for generation.
  - The cert/key live in a new `tls/` directory under the config root, owned by
    the container-mapped id and bind-mounted into the CMIS container at
    `/etc/ferrogate/tls`. A new private class `ferrogate::tls` manages them.
  - The **SHA-384 SPKI pin** MIA clients pin to authenticate CMIS is computed
    and written to `<config_dir>/cmis.spki-pin.txt` for operators.

### Changed
- The operator CLI wrapper now points at an `https://` loopback endpoint when
  TLS is enabled (the default). **Note:** the in-container `ferrogate` CLI is a
  plaintext client today; the `https` endpoint works only against a CLI build
  with F01 hybrid-PQC transport support. Set `cmis_tls_enable => false` for the
  plaintext path until that CLI ships.

## [0.3.4] - 2026-06-02

### Changed
- `mia_enable` now defaults to **`false`**. The published FerroGate image is
  CMIS-only: it ships the `cmis` server and the `ferrogate` CLI but no `mia`
  binary, and its entrypoint expects the MIA host agent to be installed on each
  machine from its OS package, not run as a container. With the old default of
  `true`, the MIA Quadlet unit failed on every run (`exec: mia: not found`,
  exit 127). Set `mia_enable => true` only against an image that bundles `mia`.

### Fixed
- The host operator CLI wrapper (`/usr/local/bin/ferrogate`) and its sudoers
  drop-in are no longer skipped when a container fails to start. `ferrogate::cli`
  was ordered after the entire `ferrogate::service` class, so any service-start
  failure (e.g. the unsupported MIA container above) skipped the CLI resources,
  leaving `ferrogate: command not found` on the host even though CMIS was
  running. The CLI is a static host script, so it is now ordered after
  `ferrogate::install` (which creates the service user it sudo's to) instead.

## [0.3.3] - 2026-06-02

### Fixed
- Rootless podman containers could not write their bind-mounted log/audit
  volumes (`tee: /opt/ferrogate/logs/cmis.log: Permission denied`, audit signer
  failures). The image runs as a non-root user (uid 10001); rootless podman
  remaps that internal id to a host subordinate id (`subid_start + uid - 1`),
  so volumes owned by the login user — which only owns container id 0 — are not
  writable by the container. `keep-id` (which would let the container keep the
  login uid) is broken on podman 5.x + EL10/UEK (crun `ping_group_range` then
  `devpts` `Invalid argument`), and idmapped mounts cannot remap the login uid
  (`mount_setattr: Operation not permitted`). Instead, `ferrogate::config` now
  owns the log/audit volumes by the *mapped* id, and `ferrogate::install`
  creates a companion `<user>-pod` account at that id (when `manage_user`) so
  the ownership is a readable named account. Docker is unaffected (no remap).
  Verified end-to-end on the target host. **Depends on stable subuids** — set
  `subid_management => 'podman'` on nodes where puppet/podman manages
  `/etc/subuid` (otherwise the ranges are purged and the container falls back to
  the overflow uid).

## [0.3.2] - 2026-06-02

### Fixed
- Rootless podman instances are now `systemctl --user start`ed rather than
  `enable --now`d. Quadlet generates the `.service` unit from the `.container`
  file, so it is transient/generated and cannot be enabled ("Unit ... is
  transient or generated"), which aborted the run and skipped the CLI stage.
  Boot autostart is already wired by the unit's `[Install]
  WantedBy=default.target` (the generator creates the wants-symlink on each
  daemon-reload; linger starts it at boot), so only a runtime `start`/`stop`
  is needed.

### Added
- `subid_management` parameter (`'usermod'` (default) / `'podman'` / `'none'`)
  plus `subid_start` / `subid_count`. On nodes where the `puppet/podman`
  module manages `/etc/subuid` and `/etc/subgid` via concat (e.g. alongside
  bastionvault), set `subid_management => 'podman'` to register the service
  user's ranges as `podman::subuid`/`podman::subgid` concat fragments. The
  previous `usermod` exec appends outside concat, so the podman module purged
  the ranges every run — a flap that breaks rootless podman. `'none'` leaves
  subid allocation entirely to an external manager.

## [0.3.1] - 2026-06-02

### Fixed
- Rootless podman Quadlet unit directory creation no longer fails on a fresh
  service-user home. `ferrogate::instance` declared only
  `~/.config/containers/systemd` (with `recurse`, which manages children, not
  parents); Puppet does not create parent directories implicitly, so on a new
  `~/.config` the leaf-dir `File` failed with "parent directory ... does not
  exist", cascading skips through the `.container` units, user daemon-reload,
  enable execs, and the CLI stage. The full chain (`~/.config` →
  `containers` → `systemd`) is now declared with ordered requires, shared
  across instances via `ensure_resource`.

## [0.3.0] - 2026-06-02

### Added
- Host-side `ferrogate` operator CLI wrapper. When CMIS is enabled the module
  installs `/usr/local/bin/ferrogate`, which re-execs into the running
  `ferrogate-cmis` container and runs the in-container operator CLI (`status`,
  `list-svids`, `revoke-svid`, `revoke-host`, `bump-epoch`). The CLI's gRPC
  client reaches CMIS over the container's own loopback, so no published host
  port or TLS trust anchor is needed; the wrapper pins `--endpoint` to the
  configured `cmis_container_port` (overridable on the command line). For
  podman it `sudo`s to the rootless service user and `podman exec`s; for docker
  it `sudo`s to root and `docker exec`s. A `/etc/sudoers.d/ferrogate-cli`
  drop-in grants passwordless access to members of the FerroGate group.

## [0.2.6] - 2026-06-02

### Fixed
- Rootless podman / `systemctl --user` execs run as the service user now set
  `cwd` to the user's home directory. Previously they inherited the Puppet
  agent's working directory (typically `/root`, mode 0700), which the
  unprivileged service user cannot access — causing podman/systemd to error on
  `getcwd`/`chdir`. Applies to the image pull, `podman system migrate`, and the
  per-instance `systemctl --user` daemon-reload/enable/disable execs.

## [0.2.5] - 2026-06-02

### Fixed
- Rootless podman image pulls failed with "potentially insufficient UIDs or
  GIDs available in user namespace" because the `system` service user had no
  `/etc/subuid` / `/etc/subgid` ranges (`useradd` does not allocate them for
  system users). `ferrogate::install` now adds a deterministic, uid-derived
  65536-id subordinate range via `usermod --add-subuids/--add-subgids` and runs
  `podman system migrate` before the pull so the new mapping takes effect.

## [0.2.4] - 2026-06-02

### Fixed
- Resolved a resource dependency cycle. `baseapp` chowns the
  `/srv/application-*` roots to the ferrogate user/group and therefore
  auto-requires `User`/`Group[ferrogate]`, which `ferrogate::install` creates.
  `ferrogate::install` is now ordered *before* `baseapp` (previously after),
  breaking the `File[/srv/application-config] -> Class[baseapp] ->
  Class[ferrogate::install] -> Group[ferrogate] -> File[...]` cycle.

## [0.2.3] - 2026-06-02

### Fixed
- `ferrogate::install` no longer collides with other modules that install the
  container runtime package. The runtime `package` is now guarded with
  `!defined()`, so it coexists with modules such as `bastionvault` that also
  install `podman`, instead of raising a duplicate `Package[podman]`
  declaration.

## [0.2.2] - 2026-06-01

### Notes
- Maintenance release. No functional changes to the `ferrogate` module.
- Confirms that `ferrogate` lets the `baseapp` module own the shared
  `/srv/application-*` roots and only manages its own `ferrogate/`
  subdirectories, so it coexists with other baseapp-consuming modules on the
  same node.

## [0.2.1] - 2026-06-01

### Added
- This changelog.

## [0.2.0] - 2026-06-01

### Added
- Initial `ferrogate` module: deploys FerroGate's CMIS and MIA servers as
  `systemd`-managed containers.
- Container runtime auto-detection via the `ferrogate_container_runtime` fact
  (podman preferred over docker), overridable with the `runtime` parameter.
- **Podman**: rootless [Quadlet](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)
  `.container` units owned by a dedicated user, started through the user's
  `systemd` instance with linger enabled.
- **Docker**: a plain system unit wrapping `docker run`, managed by the native
  `service` resource.
- Configurable image reference (`registry`, `image_name`, `image_tag`) with a
  Puppet-driven image pull.
- Dedicated unprivileged `ferrogate` service account (uid/gid 10001).
- Directory layout built on `ffquintella-baseapp` under
  `/srv/application-{config,data,logs}/ferrogate`, with an optional
  `app_environment` variant level (empty by default).
- SELinux configuration: `:Z`/`:z` volume relabeling, persistent
  `semanage fcontext` rules, and the `container_manage_cgroup` boolean for
  rootless podman.
- Per-instance environment files and the `ferrogate::instance` defined type for
  CMIS and MIA.
- rspec-puppet specs (run via `regent test`) and README.

[0.2.1]: https://github.com/ffquintella/puppet-ferrogate/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/ffquintella/puppet-ferrogate/releases/tag/v0.2.0
