# Changelog

All notable changes to this module are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this module
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
