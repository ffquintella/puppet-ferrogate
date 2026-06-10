# Changelog

All notable changes to this module are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this module
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
