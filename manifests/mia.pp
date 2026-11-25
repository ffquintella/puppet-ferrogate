# @summary Install and configure the FerroGate MIA host agent from its OS package.
#
# Standalone, self-contained class for the **Machine Identity Agent (MIA)**
# *client*. Unlike the container-based `mia_enable` switch on the main
# `ferrogate` class (which runs MIA inside the server image — see its caveats),
# this class deploys MIA the way FerroGate actually ships it: as a native host
# package that drops a static `mia` binary, a service unit, and the config
# templates under the platform config directory.
#
# It can be declared on its own, on any host that needs an agent — with **no**
# dependency on the `ferrogate` server class, `baseapp`, a container runtime, or
# the dedicated `ferrogate` service user:
#
# @example Minimal client pointing at a CMIS server (TLS by SPKI pin)
#   class { 'ferrogate::mia':
#     cmis_endpoint => 'https://cmis.prod.example.com:8443',
#     cmis_spki_pin => '5f2e...c4',   # SHA-384 SPKI pin, lowercase hex
#   }
#
# @example High availability — resolve CMIS nodes from a DNS SRV record
#   class { 'ferrogate::mia':
#     cmis_srv      => '_cmis._tcp.prod.example.com',
#     cmis_spki_pin => '5f2e...c4',   # pins every node behind the SRV record
#   }
#
# @example With a signed local-caller allowlist for the helper API
#   class { 'ferrogate::mia':
#     cmis_endpoint  => 'https://cmis.example.com:8443',
#     cmis_spki_pin  => '5f2e...c4',
#     allowlist_path => '/etc/ferrogate/allowlist.cbor',
#     allowlist_key  => '/etc/ferrogate/allowlist.pub',
#   }
#
# @example Fetch this host's allowlist from CMIS on every start (by EK-UUID)
#   class { 'ferrogate::mia':
#     cmis_endpoint          => 'https://cmis.example.com:8443',
#     cmis_spki_pin          => '5f2e...c4',
#     allowlist_path         => '/var/lib/ferrogate/allowlist.cbor',
#     allowlist_key          => '/var/lib/ferrogate/allowlist.pub',
#     allowlist_fetch        => true,
#     allowlist_max_age_secs => 86400,
#   }
#
# @example A2 bootstrap — propose this host, then remove `allowlist_propose` once approved
#   class { 'ferrogate::mia':
#     cmis_endpoint     => 'https://cmis.example.com:8443',
#     cmis_spki_pin     => '5f2e...c4',
#     allowlist_path    => '/var/lib/ferrogate/allowlist.cbor',
#     allowlist_key     => '/var/lib/ferrogate/allowlist.pub',
#     allowlist_fetch   => true,
#     allowlist_propose => true,   # bootstrap only — drop after approval
#   }
#
# ## Platform support
#
# On the **RedHat** and **Debian** families the package is an RPM/DEB installed
# through the node's package manager, the config file is a systemd
# `EnvironmentFile`, and the unit is managed via `systemd`.
#
# On **Windows** the package is a Chocolatey `.nupkg` (`provider => chocolatey`),
# the config file is written to disk as `KEY=VALUE` lines under
# `C:/ProgramData/ferrogate/mia.env`, and the bundled Windows service is managed
# via the native `windows` provider. Setting `manage_repo => true` on Windows
# registers a **custom Chocolatey source** (your private NuGet feed) the package
# is pulled from — see `repo_baseurl` / `repo_user` / `repo_password`. The
# `puppetlabs/chocolatey` module supplies the `chocolatey` provider and the
# `chocolateysource` type and must be present on the node.
#
# The package must be reachable through the node's existing package
# repositories / Chocolatey sources (this class can optionally add a custom one
# via `manage_repo`, mirroring how the server class treats the container
# runtime).
#
# ## Two config surfaces, kept in sync
#
# This class renders **both** of MIA's supported configuration files from the
# same parameters:
#
# * `<config_dir>/mia.env` — the systemd `EnvironmentFile` the **service** loads
#   (`KEY=VALUE`). It carries everything, including the hardening/runtime
#   toggles (`FERROGATE_SECCOMP`, `FERROGATE_REQUIRE_IMA`, `FERROGATE_RUN_AS_*`,
#   `extra_env`) that have no TOML equivalent.
# * `<config_dir>/mia.toml` — the TOML config file `mia` reads **directly**.
#   Interactive commands such as `mia test` do *not* inherit the service's
#   `EnvironmentFile`, so without this file they read an empty packaged template
#   and fail even when the service is healthy. It is emitted with only the
#   agent-honored keys (an unknown key makes MIA fail loudly at startup).
#
# MIA's precedence is `defaults < mia.toml < FERROGATE_* env`, so the two files
# stay consistent and the env file still wins for the running daemon. Set
# `manage_toml => false` to render only the env file.
#
# @param package_name
#   Name of the MIA package. On Windows this is the Chocolatey package id.
# @param package_ensure
#   `ensure` for the package (`'installed'`, a pinned version, `'latest'`, …).
# @param manage_package
#   Whether to manage the package. Set `false` if another module owns it.
# @param manage_repo
#   Whether to add a custom package repository before installing.
#   **Defaults to `false`** — the package is assumed reachable through the node's
#   existing repositories. When `true`, `repo_baseurl` is required and a repo is
#   declared (a `yumrepo` on the RedHat family, an apt source list on the Debian
#   family, a `chocolateysource` / custom NuGet feed on Windows) and ordered
#   before the package. When `false`, the module actively **removes** any
#   `ferrogate-mia` repo it previously added (sets the `yumrepo` / apt source /
#   Chocolatey source to `ensure => absent`, ordered before the package) so a
#   stale or broken URL — e.g. a NuGet feed baseurl mistakenly applied to a
#   RedHat host, which makes `dnf` 404 on every run — stops breaking package
#   resolution and the package falls back to a pre-existing repository. The
#   removal is an idempotent no-op on a node that never had a managed repo.
# @param repo_baseurl
#   Base URL of the custom repository. Required when `manage_repo` is `true`.
#   RedHat: the `yumrepo` `baseurl`. Debian: the `deb` line URI. Windows: the
#   Chocolatey source `location` (the custom NuGet feed URL or path).
# @param repo_descr
#   Human-readable repository name/description.
# @param repo_gpgcheck
#   Whether to verify package signatures against `repo_gpgkey`. RedHat/Debian
#   only.
# @param repo_gpgkey
#   GPG key for signature verification. RedHat: a `gpgkey` URL or local path.
#   Debian: a local keyring file path used as the source's `signed-by`. When
#   `undef`, signing is not enforced for the added source. RedHat/Debian only.
# @param repo_release
#   Debian only — the suite/codename for the `deb` line. Defaults to the node's
#   distro codename fact; required when that fact is absent.
# @param repo_components
#   Debian only — the components for the `deb` line.
# @param repo_user
#   Windows only — username for an authenticated Chocolatey source / NuGet feed.
#   Passed to `chocolateysource`. `undef` for an anonymous feed.
# @param repo_password
#   Windows only — password for an authenticated Chocolatey source / NuGet feed.
#   Required when `repo_user` is set (and `manage_repo` is `true`). Accepts a
#   plain String (e.g. an eyaml-decrypted Hiera value) or a `Sensitive` String;
#   it is wrapped/unwrapped internally. Chocolatey cannot read a configured
#   password back, so the source resource reports a change on every run once
#   this is set.
# @param repo_priority
#   Windows only — priority of the Chocolatey source (lower wins). `undef`
#   leaves Chocolatey's default (0 = unprioritized, so the public community feed
#   competes on equal footing). Set `1` to make this feed authoritative.
# @param choco_source_name
#   Windows only — name the Chocolatey source is registered under. Also the value
#   handed to `choco install --source` by default when `manage_repo` is `true`,
#   so credentials attached to the source apply to the install. Defaults to
#   `'ferrogate-mia'`.
# @param manage_chocolatey
#   Windows only — `include chocolatey` (puppetlabs/chocolatey) to bootstrap
#   Chocolatey before the source and package are managed. Defaults to `false`:
#   Chocolatey is assumed present (site baseline). Note the stock bootstrap
#   reaches out to the public community feed, usually the opposite of what a site
#   with an internal NuGet mirror wants.
# @param package_source
#   Windows only — value passed to `choco install --source`, overriding the
#   default. The default is `choco_source_name` when this class manages the
#   source (`manage_repo => true`), so configured credentials are picked up, and
#   unset otherwise (Chocolatey's configured sources are searched).
# @param install_options
#   Windows only — extra flags handed to `choco install`, e.g.
#   `['--ignore-checksums']` or `[{'--installargs' => 'quiet'}]`.
# @param service_name
#   Name of the service shipped by the package (systemd unit / Windows service).
# @param manage_service
#   Whether to manage the service resource.
# @param service_ensure
#   Run state of the service (`'running'` / `'stopped'`).
# @param service_enable
#   Whether the service starts at boot.
# @param manage_user
#   Whether to create the `_ferrogate` privilege-drop account (Linux only). The
#   `mia` daemon starts as root and drops to the `_ferrogate` user/group; the
#   package ships no scriptlet to create it, so without this the daemon exits
#   with `service user _ferrogate not found` and systemd crash-loops it. Defaults
#   to `true`. Set `false` if another module owns the account, or when you drop
#   to a different existing account via `run_as_uid` / `run_as_gid`. Ignored on
#   Windows (the service runs as `LocalSystem`).
# @param user_name
#   Name of the privilege-drop account to create. The agent resolves the literal
#   name `_ferrogate`, so change this only in tandem with `run_as_uid` /
#   `run_as_gid` pointing the daemon elsewhere. Linux only.
# @param user_shell
#   Login shell for the privilege-drop account. Defaults to `/sbin/nologin`
#   (present on the RedHat family and via merged-usr on Debian). Linux only.
# @param config_dir
#   Directory holding the MIA configuration. The package ships it; managed here
#   so the env file has a parent on a fresh node. `undef` (the default) resolves
#   to `/etc/ferrogate` on Linux and `C:/ProgramData/ferrogate` on Windows.
# @param manage_config_dir
#   Whether to manage `config_dir` as a directory.
# @param manage_allowlist_dir
#   Whether to ensure the directory holding `allowlist_path` exists (Linux and
#   Windows). Defaults to `true`. It matters chiefly for `allowlist_fetch`: the
#   daemon writes the signed allowlist body to `allowlist_path` on start and
#   fails if the parent directory is missing, and the packaged default lives at
#   `/var/lib/ferrogate`, outside `config_dir`. A no-op when `allowlist_path` is
#   unset or already resolves inside a managed `config_dir` (no duplicate
#   resource). This manages only the directory, never the allowlist body or the
#   `allowlist_key` — provision the key out of band; MIA verifies the fetched
#   body against it. Set `false` if the package or another module owns the path.
# @param manage_toml
#   Whether to also render `<config_dir>/mia.toml`, the config file `mia` reads
#   directly (so `mia test` and other interactive invocations, which do not see
#   the service's systemd `EnvironmentFile`, are configured). Defaults to `true`.
#   Set `false` to manage only `mia.env`.
# @param status_group
#   Group of *status readers* created by the package (`mia status`, `mia test`,
#   the tray). Defaults to `ferrogate-status` on Linux and `FerroGateStatus` on
#   Windows. Also the default group owner of `mia.toml` on Linux (see
#   `toml_group`).
# @param client_group
#   Group of helper-API *clients* created by the package. Defaults to
#   `ferrogate-clients` on Linux (Debian family package only) and
#   `FerroGateClients` on Windows.
# @param operators_group
#   Group of operators created by the Debian package. Defaults to
#   `ferrogate-operators`. Linux only.
# @param status_group_members
#   Users added (additively — existing members are never removed) to
#   `status_group`. On Linux each is added with `usermod -aG` and takes effect at
#   the user's next login; on Windows via the group resource (`DOMAIN\user`).
# @param client_group_members
#   Users added to `client_group` (helper-API access; the allowlist still gates
#   token minting). Same semantics as `status_group_members`.
# @param operators_group_members
#   Users added to `operators_group`. Linux only.
# @param toml_group
#   Group allowed to read `mia.toml`. On Linux it is the file's group owner;
#   on Windows it receives a read ACE (see `manage_toml_acl`). The Linux package's
#   post-install script sets it to `status_group` so desktop users can run
#   `mia test`; Puppet used to rewrite it as `root:root 0640`, locking them out.
#   Defaults to `status_group`; on Linux set `'root'` to restore the old
#   behaviour. The file stays `0640`.
# @param manage_toml_acl
#   Windows only — grant `toml_group` (default `status_group`, `FerroGateStatus`)
#   read access to `mia.toml` with `icacls`. The installer makes
#   `%ProgramData%\\FerroGate` administrator-only (protected DACL), so a file
#   created there is readable only by SYSTEM and Administrators and the group's
#   members could not run `mia test`/`mia status`. Only the file receives the
#   ACE — the directory stays locked; the mia.env file is never opened up.
# @param manage_allowlist_acl
#   Let `toml_group` (default `status_group`) update the allowlist at
#   `allowlist_path`. Linux: the allowlist directory becomes `root:<toml_group>`
#   `2775` (setgid, so files the daemon recreates keep the group) and, when the
#   file exists, it is set to group `<toml_group>` `0664` (the body is signed;
#   the file is never created here, so an empty allowlist is never written).
#   Windows: `icacls` grants the group Modify on the file (when present) and on
#   its directory — inherited by the directory's children unless that directory is
#   `config_dir`, so `mia.env` is never opened up. Windows also grants Modify on
#   the agent's synced body `<config_dir>/allowlist*.synced.cbor`. Directory/file
#   grants need `allowlist_path`; set
#   `false` to leave the permissions to the package/operator.
# @param manage_service_acl
#   Linux only — keep a read ACL for the service account (`user_name`) on
#   `mia.toml`. The hardened daemon drops to that account and clears its
#   supplementary groups, so a SIGHUP reload can only read the file through this
#   ACL (the package grants it, but Puppet rewriting the file drops it). Needs
#   `setfacl`/`getfacl` (the `acl` package).
# @param rust_log
#   `RUST_LOG` tracing filter for the agent.
# @param cmis_endpoint
#   `FERROGATE_CMIS_ENDPOINT` — the CMIS server URL. An `https://` URL is dialed
#   over hybrid-PQC TLS and authenticated by SPKI pin (see `cmis_spki_pin`);
#   `http://` is plaintext bring-up only. Mutually exclusive with `cmis_srv`.
# @param cmis_srv
#   `FERROGATE_CMIS_SRV` — a DNS SRV record advertising the CMIS nodes (e.g.
#   `_cmis._tcp.example.com`) for high availability instead of a single
#   `cmis_endpoint`. The agent resolves it, prefers records by RFC 2782
#   priority/weight, dials the best live node over hybrid-PQC TLS, and fails
#   over automatically (re-resolving so a rescaled cluster is followed). The
#   `cmis_spki_pin` authenticates every node. Mutually exclusive with
#   `cmis_endpoint`.
# @param cmis_spki_pin
#   `FERROGATE_CMIS_SPKI_PIN` — the accepted CMIS SPKI pin (lowercase-hex
#   SHA-384). The server class publishes this value at
#   `<config_dir>/cmis.spki-pin.txt` on the CMIS node.
# @param helper_socket
#   `FERROGATE_HELPER_SOCKET` — path to the local helper-API Unix socket. Its
#   presence is what *enables* the helper API; with none set MIA logs a banner
#   and exits, so this defaults to the documented `/run/ferrogate/mia.sock`
#   (systemd provisions `/run/ferrogate`). Set to `undef` to leave it unset. The
#   Unix-socket default is **Linux-only**: on Windows the helper API uses a named
#   pipe, so the default is dropped there — set an explicit pipe value if needed.
# @param helper_socket_mode
#   `FERROGATE_HELPER_SOCKET_MODE` — octal mode (as a string) for the helper
#   socket. Linux only.
# @param helper_require_authenticode
#   `FERROGATE_HELPER_REQUIRE_AUTHENTICODE` / `[helper] require_authenticode` —
#   **Windows only.** Require a valid Authenticode signature on every local
#   caller's executable (refused as `untrusted-binary` otherwise). `undef` (the
#   default) renders nothing, so MIA keeps its default of *requiring* it. Set
#   `false` for environments whose clients (and `mia` itself) are not
#   code-signed. Written to both `mia.toml` (what the tray configuration screen
#   reads) and `mia.env`. Takes effect after the `mia` service restarts.
# @param allowlist_path
#   `FERROGATE_ALLOWLIST` — signed CBOR allowlist of vetted local callers. When
#   unset the helper API denies every caller (fail closed). When set,
#   `allowlist_key` is required.
# @param allowlist_key
#   `FERROGATE_ALLOWLIST_KEY` — trusted CMIS enrollment public key used to
#   verify the allowlist signature. Required whenever `allowlist_path` is set.
# @param allowlist_key_base64
#   Base64 of the (binary) enrollment public key. When set, the module writes the
#   decoded bytes to `allowlist_key` and makes it readable by the ferrogate groups
#   (Windows: `icacls` read for `status_group` and `client_group`; Linux: `0644`,
#   group `toml_group`). Whitespace/line breaks in the value are ignored, so a
#   folded YAML scalar works. Requires `allowlist_key`. Leave `undef` to provision
#   the key out of band.
# @param allowlist_max_age_secs
#   `FERROGATE_ALLOWLIST_MAX_AGE_SECS` / `[allowlist] max_age_secs` — maximum
#   accepted allowlist age, in seconds.
# @param allowlist_fetch
#   `FERROGATE_ALLOWLIST_FETCH` / `[allowlist] fetch` — when `true`, MIA pulls
#   this host's allowlist from CMIS on each start, keyed by its EK-UUID, and
#   writes the signed body to `allowlist_path` (verified against `allowlist_key`).
#   Requires `allowlist_path` (and hence `allowlist_key`). Leave `undef` to take
#   the agent default (no fetch).
# @param allowlist_propose
#   `FERROGATE_ALLOWLIST_PROPOSE` / `[allowlist] propose` — enable **only** for
#   the A2 bootstrap path: MIA proposes this host to CMIS for allowlisting.
#   **Remove it (set back to `undef`/`false`) once the host is approved** — it is
#   not a steady-state setting. Requires `allowlist_path`. Leave `undef` to take
#   the agent default (do not propose).
# @param allowlist_propose_interval_secs
#   `FERROGATE_ALLOWLIST_PROPOSE_INTERVAL_SECS` / `[allowlist] propose_interval_secs`
#   — how often (seconds) MIA re-sends its proposal while awaiting approval on the
#   A2 bootstrap path. Only meaningful with `allowlist_propose => true`. Leave
#   `undef` to take the agent default.
# @param ima_log
#   `FERROGATE_IMA_LOG` — override the IMA runtime-measurement log path. Linux
#   only.
# @param attest_backend
#   `FERROGATE_ATTEST_BACKEND` / `[attestation] backend` — which backend the
#   agent attests with to obtain its host SVID. `'host-key'` (the agent default,
#   emitted when this is `undef`) is the TPM-less production profile — a hardware
#   fingerprint plus a machine signing key — and works on every platform.
#   `'virtual-tpm'` runs the full TPM attestation handshake against an **insecure,
#   in-process software TPM** with no hardware root of trust: it is **dev/test
#   only** and never for production. It also requires a `mia` build compiled with
#   the off-by-default `virtual-tpm` cargo feature (a stock release binary refuses
#   it and fails closed), and only succeeds against a CMIS configured to trust the
#   synthetic EK root and PCR digest the agent logs at startup. There is no
#   software-TPM emulator (e.g. `swtpm`) to install — the virtual TPM lives inside
#   the `mia` process. Leave `undef` to take the agent default.
# @param seccomp
#   `FERROGATE_SECCOMP` — seccomp mode for staged rollout: `'enforce'`
#   (default in the agent), `'audit'` (log violations) or `'off'`. Leave `undef`
#   to take the agent default. Linux only.
# @param require_ima
#   Maps to `FERROGATE_REQUIRE_IMA`. `false` emits `FERROGATE_REQUIRE_IMA=0`
#   (do not require enforced IMA — dev/CI only); `true` emits `1`. Leave `undef`
#   to take the agent default (require IMA). Linux only.
# @param skip_hardening
#   When `true`, set `FERROGATE_SKIP_HARDENING=1` to disable the whole hardening
#   profile. **Development only** — never in production. Linux only.
# @param run_as_uid
#   `FERROGATE_RUN_AS_UID` — drop to this UID instead of resolving `_ferrogate`.
#   Linux only.
# @param run_as_gid
#   `FERROGATE_RUN_AS_GID` — drop to this GID instead of resolving `_ferrogate`.
#   Linux only.
# @param extra_env
#   Extra environment variables merged verbatim into the config file.
class ferrogate::mia (
  String[1]                       $package_name           = 'ferrogate-mia',
  String[1]                       $package_ensure         = 'installed',
  Boolean                         $manage_package         = true,
  Boolean                         $manage_repo            = false,
  Optional[String[1]]             $repo_baseurl           = undef,
  String[1]                       $repo_descr             = 'FerroGate MIA',
  Boolean                         $repo_gpgcheck          = true,
  Optional[String[1]]             $repo_gpgkey            = undef,
  Optional[String[1]]             $repo_release           = undef,
  String[1]                       $repo_components        = 'main',
  Optional[String[1]]             $repo_user              = undef,
  Optional[Variant[String[1], Sensitive[String[1]]]] $repo_password = undef,
  Optional[Integer[0]]            $repo_priority          = undef,
  String[1]                       $choco_source_name      = 'ferrogate-mia',
  Boolean                         $manage_chocolatey      = false,
  Optional[String[1]]             $package_source         = undef,
  Array[Variant[String[1], Hash[String[1], String]]] $install_options = [],
  String[1]                       $service_name           = 'mia',
  Boolean                         $manage_service         = true,
  Enum['running', 'stopped']      $service_ensure         = 'running',
  Boolean                         $service_enable         = true,
  Boolean                         $manage_user            = true,
  String[1]                       $user_name              = '_ferrogate',
  Stdlib::Absolutepath            $user_shell             = '/sbin/nologin',
  Optional[Stdlib::Absolutepath]  $config_dir             = undef,
  Boolean                         $manage_config_dir      = true,
  Boolean                         $manage_allowlist_dir   = true,
  Boolean                         $manage_toml            = true,
  Optional[String[1]]             $status_group           = undef,
  Optional[String[1]]             $client_group           = undef,
  String[1]                       $operators_group        = 'ferrogate-operators',
  Array[String[1]]                $status_group_members   = [],
  Array[String[1]]                $client_group_members   = [],
  Array[String[1]]                $operators_group_members = [],
  Optional[String[1]]             $toml_group             = undef,
  Boolean                         $manage_service_acl     = true,
  Boolean                         $manage_toml_acl        = true,
  Boolean                         $manage_allowlist_acl   = true,
  String[1]                       $rust_log               = 'info',
  Optional[String[1]]             $cmis_endpoint          = undef,
  Optional[String[1]]             $cmis_srv               = undef,
  Optional[String[1]]             $cmis_spki_pin          = undef,
  Optional[String[1]]             $helper_socket          = '/run/ferrogate/mia.sock',
  Optional[String[1]]             $helper_socket_mode     = '660',
  Optional[Boolean]               $helper_require_authenticode = undef,
  Optional[Stdlib::Absolutepath]  $allowlist_path         = undef,
  Optional[Stdlib::Absolutepath]  $allowlist_key          = undef,
  Optional[String[1]]             $allowlist_key_base64   = undef,
  Optional[Integer[1]]            $allowlist_max_age_secs = undef,
  Optional[Boolean]               $allowlist_fetch        = undef,
  Optional[Boolean]               $allowlist_propose      = undef,
  Optional[Integer[1]]            $allowlist_propose_interval_secs = undef,
  Optional[Stdlib::Absolutepath]  $ima_log                = undef,
  Optional[Enum['host-key', 'virtual-tpm']] $attest_backend = undef,
  Optional[Enum['enforce', 'audit', 'off']] $seccomp      = undef,
  Optional[Boolean]               $require_ima            = undef,
  Boolean                         $skip_hardening         = false,
  Optional[Integer[0]]            $run_as_uid             = undef,
  Optional[Integer[0]]            $run_as_gid             = undef,
  Hash[String[1], String]         $extra_env              = {},
) {
  # A signed allowlist is verified against the CMIS enrollment key; the agent
  # rejects a path with no key, so fail fast here with a clearer message.
  if $allowlist_path and !$allowlist_key {
    fail('ferrogate::mia: allowlist_key is required whenever allowlist_path is set.')
  }

  if $allowlist_key_base64 and !$allowlist_key {
    fail('ferrogate::mia: allowlist_key_base64 requires allowlist_key (the destination path).')
  }

  # fetch/propose act on the allowlist body at `allowlist_path` (fetch writes it,
  # verified against `allowlist_key`); they are meaningless without one, so fail
  # fast rather than emitting an orphaned toggle the agent ignores or rejects.
  if ($allowlist_fetch or $allowlist_propose or $allowlist_propose_interval_secs) and !$allowlist_path {
    fail('ferrogate::mia: allowlist_fetch, allowlist_propose and allowlist_propose_interval_secs require allowlist_path (and allowlist_key) to be set.')
  }

  # The propose interval only governs the propose loop; setting it without
  # enabling propose is a silent no-op — catch the mistake at compile time.
  if $allowlist_propose_interval_secs and !$allowlist_propose {
    fail('ferrogate::mia: allowlist_propose_interval_secs requires allowlist_propose => true.')
  }

  # The agent accepts a single endpoint OR an SRV record, never both; catch the
  # conflict at compile time rather than letting the daemon reject it at runtime.
  if $cmis_endpoint and $cmis_srv {
    fail('ferrogate::mia: cmis_endpoint and cmis_srv are mutually exclusive — set only one.')
  }

  # --- Resolve platform-specific defaults -----------------------------------
  # Windows installs from Chocolatey and runs a native Windows service; the
  # POSIX families install an RPM/DEB and run a systemd unit. The config file is
  # the same KEY=VALUE surface on every platform (a systemd EnvironmentFile on
  # Linux, a plain config file read by the agent on Windows).
  $_windows = $facts['os']['family'] == 'windows'

  if $config_dir {
    $_config_dir = $config_dir
  } elsif $_windows {
    $_config_dir = 'C:/ProgramData/ferrogate'
  } else {
    $_config_dir = '/etc/ferrogate'
  }
  $env_file  = "${_config_dir}/mia.env"
  $toml_file = "${_config_dir}/mia.toml"

  if $_windows {
    # Windows file ACLs/modes differ from POSIX; let the resources default
    # rather than forcing a root:root 0640 that does not apply.
    $_owner            = undef
    $_group            = undef
    $_dir_mode         = undef
    $_file_mode        = undef
    $_service_provider = 'windows'
    $_package_provider = 'chocolatey'
    $_status_group     = pick($status_group, 'FerroGateStatus')
    $_client_group     = pick($client_group, 'FerroGateClients')
    $_toml_group       = undef
    $_toml_acl_group   = pick($toml_group, $_status_group)
  } else {
    $_owner            = 'root'
    $_group            = 'root'
    $_dir_mode         = '0755'
    $_file_mode        = '0640'
    $_service_provider = 'systemd'
    $_package_provider = undef
    $_status_group     = pick($status_group, 'ferrogate-status')
    $_client_group     = pick($client_group, 'ferrogate-clients')
    $_toml_group       = pick($toml_group, $_status_group)
    $_toml_acl_group   = undef
  }

  # The helper-API default (`/run/ferrogate/mia.sock`) is a Unix socket; on
  # Windows the helper API is a named pipe, so drop the inapplicable Unix
  # default there (an explicit value is still honoured).
  if $_windows and $helper_socket == '/run/ferrogate/mia.sock' {
    $_helper_socket = undef
  } else {
    $_helper_socket = $helper_socket
  }

  # Chocolatey cannot attach a username to a source without a password; fail
  # fast rather than registering a feed that 401s on every run.
  if $_windows and $manage_repo and $repo_user and !$repo_password {
    fail('ferrogate::mia: repo_user is set but repo_password is unset.')
  }

  # Unwrap the feed password only at the point of use (the chocolateysource
  # property); accept both a plain String and a Sensitive String.
  $_repo_password = $repo_password ? {
    Sensitive => $repo_password.unwrap,
    default   => $repo_password,
  }

  # Windows only: optionally bootstrap Chocolatey itself ahead of the source and
  # the package.
  if $_windows and $manage_chocolatey {
    include chocolatey
  }

  # `choco install --source`: prefer the source *name* over the raw URL so the
  # credentials stored on the registered source apply to the install. Without a
  # managed source nothing is passed unless `package_source` says so, leaving
  # Chocolatey's configured sources in charge. Windows only.
  if $_windows {
    $_package_source = $package_source ? {
      undef   => $manage_repo ? {
        true    => $choco_source_name,
        default => undef,
      },
      default => $package_source,
    }
    $_install_options = $install_options.empty ? {
      true    => undef,
      default => $install_options,
    }
  } else {
    $_package_source  = undef
    $_install_options = undef
  }

  # --- Optional custom package repository (off by default) ------------------
  # When `manage_repo` is false the package is expected to resolve through a
  # repository already present on the node, so we do not add one. We do, however,
  # actively *remove* any `ferrogate-mia` repo this module previously added: a
  # `yumrepo`/apt source/Chocolatey source left on disk keeps `dnf`/`apt` hitting
  # its (possibly dead) URL on every run — e.g. a stale NuGet feed baseurl that
  # 404s — even though nothing declares it anymore. Ensuring it absent is an
  # idempotent no-op on a node that never had one, and lets the package fall back
  # to the pre-existing repository.
  if $manage_repo {
    if !$repo_baseurl {
      fail('ferrogate::mia: repo_baseurl is required when manage_repo is true.')
    }

    case $facts['os']['family'] {
      'RedHat': {
        yumrepo { 'ferrogate-mia':
          ensure   => present,
          descr    => $repo_descr,
          baseurl  => $repo_baseurl,
          enabled  => 1,
          gpgcheck => $repo_gpgcheck ? { true => 1, default => 0 },
          gpgkey   => $repo_gpgkey,
        }
        if $manage_package {
          Yumrepo['ferrogate-mia'] -> Package[$package_name]
        }
      }
      'Debian': {
        # Resolve the suite/codename: explicit param, else the distro fact.
        if $repo_release {
          $_suite = $repo_release
        } elsif $facts['os']['distro'] and $facts['os']['distro']['codename'] {
          $_suite = $facts['os']['distro']['codename']
        } else {
          fail('ferrogate::mia: repo_release is required on Debian when the distro codename fact is absent.')
        }

        # `signed-by` pins the source to a local keyring when one is supplied.
        $_signed_by = $repo_gpgkey ? {
          undef   => '',
          default => "[signed-by=${repo_gpgkey}] ",
        }

        file { '/etc/apt/sources.list.d/ferrogate-mia.list':
          ensure  => file,
          owner   => 'root',
          group   => 'root',
          mode    => '0644',
          content => "# Managed by Puppet (ferrogate::mia) — ${repo_descr}\ndeb ${_signed_by}${repo_baseurl} ${_suite} ${repo_components}\n",
        }

        # Refresh the apt cache when the source changes so the package resolves.
        exec { 'ferrogate-mia-apt-update':
          command     => 'apt-get update',
          path        => ['/usr/bin', '/bin'],
          refreshonly => true,
          subscribe   => File['/etc/apt/sources.list.d/ferrogate-mia.list'],
        }

        File['/etc/apt/sources.list.d/ferrogate-mia.list'] -> Exec['ferrogate-mia-apt-update']
        if $manage_package {
          File['/etc/apt/sources.list.d/ferrogate-mia.list'] -> Package[$package_name]
          Exec['ferrogate-mia-apt-update'] -> Package[$package_name]
        }
      }
      'windows': {
        # Register a custom Chocolatey source (private NuGet feed) the package is
        # pulled from. Requires the puppetlabs/chocolatey module for the type.
        chocolateysource { $choco_source_name:
          ensure   => present,
          location => $repo_baseurl,
          user     => $repo_user,
          password => $_repo_password,
          priority => $repo_priority,
        }
        if $manage_chocolatey {
          Class['chocolatey'] -> Chocolateysource[$choco_source_name]
        }
        if $manage_package {
          Chocolateysource[$choco_source_name] -> Package[$package_name]
        }
      }
      default: {
        fail("ferrogate::mia: manage_repo is not supported on os family '${facts['os']['family']}'.")
      }
    }
  } else {
    # Repo management disabled: tear down any repo this module may have added so a
    # stale/broken URL stops breaking package resolution, and order the removal
    # before the package so the very next `dnf`/`apt` run is already clean.
    case $facts['os']['family'] {
      'RedHat': {
        yumrepo { 'ferrogate-mia':
          ensure => absent,
        }
        if $manage_package {
          Yumrepo['ferrogate-mia'] -> Package[$package_name]
        }
      }
      'Debian': {
        file { '/etc/apt/sources.list.d/ferrogate-mia.list':
          ensure => absent,
        }
        if $manage_package {
          File['/etc/apt/sources.list.d/ferrogate-mia.list'] -> Package[$package_name]
        }
      }
      'windows': {
        chocolateysource { $choco_source_name:
          ensure => absent,
        }
        if $manage_chocolatey {
          Class['chocolatey'] -> Chocolateysource[$choco_source_name]
        }
        if $manage_package {
          Chocolateysource[$choco_source_name] -> Package[$package_name]
        }
      }
      default: {
        # Other families never had a managed repo; nothing to remove.
      }
    }
  }

  # The daemon starts as root (see the shipped unit) and drops privileges to the
  # `_ferrogate` user/group itself. The package ships no scriptlet to create that
  # account, so on a stock host `mia` exits with `service user _ferrogate not
  # found` and systemd crash-loops it — never binding the helper socket. Create
  # the account here (Linux only; Windows runs the service as LocalSystem).
  if $manage_user and !$_windows {
    group { $user_name:
      ensure => present,
      system => true,
    }
    user { $user_name:
      ensure     => present,
      system     => true,
      gid        => $user_name,
      shell      => $user_shell,
      home       => '/nonexistent',
      managehome => false,
      comment    => 'FerroGate MIA privilege-drop account',
      require    => Group[$user_name],
    }
  }

  if $manage_package {
    package { $package_name:
      ensure          => $package_ensure,
      provider        => $_package_provider,
      source          => $_package_source,
      install_options => $_install_options,
    }
    if $_windows and $manage_chocolatey {
      Class['chocolatey'] -> Package[$package_name]
    }
  }

  if $manage_config_dir {
    file { $_config_dir:
      ensure => directory,
      owner  => $_owner,
      group  => $_group,
      mode   => $_dir_mode,
    }
  }

  # The allowlist body lives at `allowlist_path`, which may sit outside
  # `config_dir` (the packaged default is /var/lib/ferrogate). With
  # `allowlist_fetch` the daemon writes the signed body there on start and fails
  # if the directory is missing, so ensure it exists. Skip when it resolves to a
  # `config_dir` that is already managed above, to avoid a duplicate File[].
  $_allowlist_dir = $allowlist_path ? {
    undef   => undef,
    default => dirname($allowlist_path),
  }
  # Manage it only when asked, and not when it duplicates an already-managed
  # config_dir.
  $_manage_allowlist_dir = $allowlist_path and $manage_allowlist_dir and !($manage_config_dir and $_allowlist_dir == $_config_dir)
  if $_manage_allowlist_dir {
    if !$_windows and $manage_allowlist_acl {
      $_allowlist_dir_group = $_toml_group
      $_allowlist_dir_mode  = '2775'
    } else {
      $_allowlist_dir_group = $_group
      $_allowlist_dir_mode  = $_dir_mode
    }
    file { $_allowlist_dir:
      ensure => directory,
      owner  => $_owner,
      group  => $_allowlist_dir_group,
      mode   => $_allowlist_dir_mode,
    }
    if $manage_package {
      Package[$package_name] -> File[$_allowlist_dir]
    }
  }

  # systemd EnvironmentFile read by the shipped `mia` unit on Linux
  # (EnvironmentFile=-/etc/ferrogate/mia.env), or the plain KEY=VALUE config
  # file the agent reads on Windows. Env vars override the optional TOML, so
  # this single file is the authoritative, unattended-provisioning
  # configuration surface.
  file { $env_file:
    ensure  => file,
    owner   => $_owner,
    group   => $_group,
    mode    => $_file_mode,
    content => epp('ferrogate/mia-client.env.epp', {
        'rust_log'               => $rust_log,
        'cmis_endpoint'          => $cmis_endpoint,
        'cmis_srv'               => $cmis_srv,
        'cmis_spki_pin'          => $cmis_spki_pin,
        'helper_socket'          => $_helper_socket,
        'helper_socket_mode'     => $helper_socket_mode,
        'helper_require_authenticode' => $helper_require_authenticode,
        'allowlist_path'         => $allowlist_path,
        'allowlist_key'          => $allowlist_key,
        'allowlist_max_age_secs' => $allowlist_max_age_secs,
        'allowlist_fetch'        => $allowlist_fetch,
        'allowlist_propose'      => $allowlist_propose,
        'allowlist_propose_interval_secs' => $allowlist_propose_interval_secs,
        'ima_log'                => $ima_log,
        'attest_backend'         => $attest_backend,
        'seccomp'                => $seccomp,
        'require_ima'            => $require_ima,
        'skip_hardening'         => $skip_hardening,
        'run_as_uid'             => $run_as_uid,
        'run_as_gid'             => $run_as_gid,
        'extra_env'              => $extra_env,
    }),
  }

  # The TOML config file `mia` reads directly. `mia test` and other interactive
  # commands do not inherit the systemd EnvironmentFile above, so without this
  # they read the empty packaged template and fail; the daemon also overlays
  # FERROGATE_* env on top of it, so the two files stay consistent. Emit only
  # agent-honored keys — an unknown key makes MIA fail loudly at startup.
  if $manage_toml {
    file { $toml_file:
      ensure  => file,
      owner   => $_owner,
      group   => $_toml_group,
      mode    => $_file_mode,
      content => epp('ferrogate/mia-client.toml.epp', {
          'rust_log'               => $rust_log,
          'cmis_endpoint'          => $cmis_endpoint,
          'cmis_srv'               => $cmis_srv,
          'cmis_spki_pin'          => $cmis_spki_pin,
          'helper_socket'          => $_helper_socket,
          'helper_socket_mode'     => $helper_socket_mode,
          'helper_require_authenticode' => $helper_require_authenticode,
          'allowlist_path'         => $allowlist_path,
          'allowlist_key'          => $allowlist_key,
          'allowlist_max_age_secs' => $allowlist_max_age_secs,
          'allowlist_fetch'        => $allowlist_fetch,
          'allowlist_propose'      => $allowlist_propose,
          'allowlist_propose_interval_secs' => $allowlist_propose_interval_secs,
          'ima_log'                => $ima_log,
          'attest_backend'         => $attest_backend,
      }),
    }
  }

  # The daemon reads mia.toml too, so it must be in place before the package's
  # service starts and a change should refresh the service alongside the env file.
  $_config_files = $manage_toml ? {
    true    => [File[$env_file], File[$toml_file]],
    default => [File[$env_file]],
  }

  if $manage_config_dir {
    File[$_config_dir] -> File[$env_file]
    if $manage_toml {
      File[$_config_dir] -> File[$toml_file]
    }
  }
  if $manage_package {
    Package[$package_name] -> File[$env_file]
    if $manage_toml {
      Package[$package_name] -> File[$toml_file]
    }
  }

  # The agent daemon drops to `user_name` and clears supplementary groups, so a
  # SIGHUP reload reads `mia.toml` only through a file ACL. The package sets it,
  # but Puppet replaces the file on every content change, discarding the ACL.
  if !$_windows and $manage_toml and $manage_service_acl {
    exec { 'ferrogate-mia-toml-acl':
      command  => "setfacl --modify user:${user_name}:r-- -- ${toml_file}",
      unless   => "getfacl --absolute-names ${toml_file} 2>/dev/null | grep -q '^user:${user_name}:r'",
      path     => ['/usr/sbin', '/usr/bin', '/sbin', '/bin'],
      provider => shell,
      require  => File[$toml_file],
    }
  }

  # Windows: the installer locks %ProgramData%\\FerroGate to SYSTEM and
  # Administrators, and a file created there inherits that, so the status-group
  # members the installer enrols could not read mia.toml. Grant the group read on
  # the file only (never the directory, never mia.env); `icacls /grant` is
  # additive and the `unless` probe keeps the run idempotent and self-healing.
  if $_windows and $manage_toml and $manage_toml_acl {
    # icacls goes through the Win32 file APIs, which accept `/` separators.
    $_toml_win  = $toml_file
    $_icacls    = 'C:\\Windows\\System32\\icacls.exe'
    exec { 'ferrogate-mia-toml-acl':
      command  => "${_icacls} \"${_toml_win}\" /grant \"${_toml_acl_group}:(R)\"",
      unless   => "C:\\Windows\\System32\\cmd.exe /s /c \"${_icacls} \"${_toml_win}\" | C:\\Windows\\System32\\findstr.exe /i /c:\"${_toml_acl_group}:(R)\"\"",
      provider => 'windows',
      require  => File[$toml_file],
    }
    if $manage_package {
      Package[$package_name] -> Exec['ferrogate-mia-toml-acl']
    }

    # The directory itself also needs the group: read + traverse (RX), applied to
    # the folder only (no (OI)/(CI) inheritance), so mia.env and other children
    # stay administrator-only.
    $_dir_win = $_config_dir
    exec { 'ferrogate-mia-dir-acl':
      command  => "${_icacls} \"${_dir_win}\" /grant \"${_toml_acl_group}:(RX)\"",
      unless   => "C:\\Windows\\System32\\cmd.exe /s /c \"${_icacls} \"${_dir_win}\" | C:\\Windows\\System32\\findstr.exe /i /c:\"${_toml_acl_group}:(RX)\"\"",
      provider => 'windows',
      before   => Exec['ferrogate-mia-toml-acl'],
    }
    if $manage_package {
      Package[$package_name] -> Exec['ferrogate-mia-dir-acl']
    }
    if $manage_config_dir {
      File[$_config_dir] -> Exec['ferrogate-mia-dir-acl']
    }
  }

  # Let the status group update the allowlist. Linux: group-own the file when it
  # exists (no `ensure`, so it is never created empty). Windows: Modify via icacls.
  if $allowlist_path and $manage_allowlist_acl {
    if $_windows {
      $_al_icacls = 'C:\\Windows\\System32\\icacls.exe'
      $_al_cmd    = 'C:\\Windows\\System32\\cmd.exe'
      $_al_find   = 'C:\\Windows\\System32\\findstr.exe'
      $_al_inherit = $_allowlist_dir ? {
        $_config_dir => '',
        default      => '(OI)(CI)',
      }
      exec { 'ferrogate-mia-allowlist-dir-acl':
        command  => "${_al_icacls} \"${_allowlist_dir}\" /grant \"${_toml_acl_group}:${_al_inherit}(M)\"",
        unless   => "${_al_cmd} /s /c \"${_al_icacls} \"${_allowlist_dir}\" | ${_al_find} /i /r /c:\"${_toml_acl_group}:.*(M)\"\"",
        provider => 'windows',
      }
      exec { 'ferrogate-mia-allowlist-file-acl':
        command  => "${_al_icacls} \"${allowlist_path}\" /grant \"${_toml_acl_group}:(M)\"",
        onlyif   => "${_al_cmd} /s /c \"if exist \"${allowlist_path}\" (exit 0) else (exit 1)\"",
        unless   => "${_al_cmd} /s /c \"${_al_icacls} \"${allowlist_path}\" | ${_al_find} /i /r /c:\"${_toml_acl_group}:.*(M)\"\"",
        provider => 'windows',
        require  => Exec['ferrogate-mia-allowlist-dir-acl'],
      }
      if $manage_package {
        Package[$package_name] -> Exec['ferrogate-mia-allowlist-dir-acl']
      }
      if $_manage_allowlist_dir {
        File[$_allowlist_dir] -> Exec['ferrogate-mia-allowlist-dir-acl']
      }
    } else {
      file { $allowlist_path:
        group => $_toml_group,
        mode  => '0664',
      }
      if $manage_package {
        Package[$package_name] -> File[$allowlist_path]
      }
      if $_manage_allowlist_dir {
        File[$_allowlist_dir] -> File[$allowlist_path]
      }
    }
  }

  # Windows: the agent keeps the CMIS-synced allowlist body and its state in the
  # config dir (`allowlist.synced.cbor` / `allowlist.state`) and writes them atomically, i.e. it creates new
  # files there. So the group gets Modify on the config dir itself (not inherited:
  # mia.env gets no ACE) and on the two files when they exist. Explicit names, no
  # wildcards: icacls mis-parsed `C:/dir/allowlist*.x` as `C:allowlist*.x`. Each
  # file exec is guarded by an existence check so a first run before the agent has
  # synced anything is a no-op instead of a failure.
  if $_windows and $manage_allowlist_acl {
    $_sy_dir  = regsubst($_config_dir, '/', '\\', 'G')
    $_sy_cmd  = 'C:\\Windows\\System32\\cmd.exe'
    $_sy_ic   = 'C:\\Windows\\System32\\icacls.exe'
    $_sy_find = 'C:\\Windows\\System32\\findstr.exe'

    exec { 'ferrogate-mia-config-dir-modify-acl':
      command  => "${_sy_ic} \"${_config_dir}\" /grant \"${_toml_acl_group}:(M)\"",
      unless   => "${_sy_cmd} /s /c \"${_sy_ic} \"${_config_dir}\" | ${_sy_find} /i /r /c:\"${_toml_acl_group}:.*(M)\"\"",
      provider => 'windows',
    }
    if $manage_package {
      Package[$package_name] -> Exec['ferrogate-mia-config-dir-modify-acl']
    }
    if $manage_config_dir {
      File[$_config_dir] -> Exec['ferrogate-mia-config-dir-modify-acl']
    }

    $_sy_file = "${_config_dir}/allowlist.synced.cbor"
    exec { 'ferrogate-mia-synced-allowlist-acl':
      command  => "${_sy_ic} \"${_sy_file}\" /grant \"${_toml_acl_group}:(M)\"",
      onlyif   => "${_sy_cmd} /s /c \"if exist \"${_sy_file}\" (exit 0) else (exit 1)\"",
      unless   => "${_sy_cmd} /s /c \"${_sy_ic} \"${_sy_file}\" | ${_sy_find} /i /r /c:\"${_toml_acl_group}:.*(M)\"\"",
      provider => 'windows',
      require  => Exec['ferrogate-mia-config-dir-modify-acl'],
    }

    $_st_file = "${_config_dir}/allowlist.state"
    exec { 'ferrogate-mia-state-allowlist-acl':
      command  => "${_sy_ic} \"${_st_file}\" /grant \"${_toml_acl_group}:(M)\"",
      onlyif   => "${_sy_cmd} /s /c \"if exist \"${_st_file}\" (exit 0) else (exit 1)\"",
      unless   => "${_sy_cmd} /s /c \"${_sy_ic} \"${_st_file}\" | ${_sy_find} /i /r /c:\"${_toml_acl_group}:.*(M)\"\"",
      provider => 'windows',
      require  => Exec['ferrogate-mia-config-dir-modify-acl'],
    }
  }

  # Enrollment public key delivered from Hiera as base64 (it is binary, so it
  # cannot live in a plain YAML string). Public material: readable by the
  # ferrogate groups, writable only by the administrators.
  if $allowlist_key and $allowlist_key_base64 {
    $_key_dir = dirname($allowlist_key)
    file { $allowlist_key:
      ensure  => file,
      content => Binary($allowlist_key_base64.regsubst('\\s', '', 'G'), '%B'),
      owner   => $_owner,
      group   => $_toml_group,
      mode    => $_windows ? {
        true    => undef,
        default => '0644',
      },
    }
    if $manage_package {
      Package[$package_name] -> File[$allowlist_key]
    }
    if $manage_config_dir and $_key_dir == $_config_dir {
      File[$_config_dir] -> File[$allowlist_key]
    }
    if $_manage_allowlist_dir and $_key_dir == $_allowlist_dir {
      File[$_allowlist_dir] -> File[$allowlist_key]
    }

    if $_windows {
      $_key_ic   = 'C:\\Windows\\System32\\icacls.exe'
      $_key_cmd  = 'C:\\Windows\\System32\\cmd.exe'
      $_key_find = 'C:\\Windows\\System32\\findstr.exe'
      unique([$_status_group, $_client_group, $_toml_acl_group]).each |String $_g| {
        exec { "ferrogate-mia-allowlist-key-acl-${_g}":
          command  => "${_key_ic} \"${allowlist_key}\" /grant \"${_g}:(R)\"",
          unless   => "${_key_cmd} /s /c \"${_key_ic} \"${allowlist_key}\" | ${_key_find} /i /c:\"${_g}:(R)\"\"",
          provider => 'windows',
          require  => File[$allowlist_key],
        }
      }
    }
  }

  # Group membership. The package creates the groups; membership is additive —
  # nobody is ever removed.
  if $_windows {
    $_win_groups = {
      $_status_group => $status_group_members,
      $_client_group => $client_group_members,
    }
    $_win_groups.each |$_grp, $_members| {
      unless $_members.empty {
        group { $_grp:
          ensure          => present,
          provider        => 'windows_adsi',
          members         => $_members,
          auth_membership => false,
        }
        if $manage_package {
          Package[$package_name] -> Group[$_grp]
        }
      }
    }
  } else {
    $_lin_groups = {
      $_status_group   => $status_group_members,
      $_client_group   => $client_group_members,
      $operators_group => $operators_group_members,
    }
    $_lin_groups.each |$_grp, $_members| {
      $_members.each |$_member| {
        exec { "ferrogate-mia-${_grp}-${_member}":
          command  => "usermod -aG ${_grp} -- ${_member}",
          unless   => "id -nG -- ${_member} | tr ' ' '\\n' | grep -qx -- ${_grp}",
          path     => ['/usr/sbin', '/usr/bin', '/sbin', '/bin'],
          provider => shell,
        }
        if $manage_package {
          Package[$package_name] -> Exec["ferrogate-mia-${_grp}-${_member}"]
        }
      }
    }
  }

  if $manage_service {
    service { $service_name:
      ensure    => $service_ensure ? { 'running' => 'running', default => 'stopped' },
      enable    => $service_enable,
      provider  => $_service_provider,
      subscribe => $_config_files,
    }
    if $manage_package {
      Package[$package_name] -> Service[$service_name]
    }
    # The account must exist before the daemon starts and drops to it.
    if $manage_user and !$_windows {
      User[$user_name] -> Service[$service_name]
    }
    # With allowlist_fetch the daemon writes the fetched body here on start, so
    # the directory must exist first.
    if $_manage_allowlist_dir {
      File[$_allowlist_dir] -> Service[$service_name]
    }
  }
}
