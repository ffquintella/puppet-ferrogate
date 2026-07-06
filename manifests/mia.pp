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
#   before the package.
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
#   Set together with `repo_user`.
# @param repo_priority
#   Windows only — priority of the Chocolatey source (lower wins). `undef`
#   leaves Chocolatey's default.
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
# @param manage_toml
#   Whether to also render `<config_dir>/mia.toml`, the config file `mia` reads
#   directly (so `mia test` and other interactive invocations, which do not see
#   the service's systemd `EnvironmentFile`, are configured). Defaults to `true`.
#   Set `false` to manage only `mia.env`.
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
# @param allowlist_path
#   `FERROGATE_ALLOWLIST` — signed CBOR allowlist of vetted local callers. When
#   unset the helper API denies every caller (fail closed). When set,
#   `allowlist_key` is required.
# @param allowlist_key
#   `FERROGATE_ALLOWLIST_KEY` — trusted CMIS enrollment public key used to
#   verify the allowlist signature. Required whenever `allowlist_path` is set.
# @param allowlist_max_age_secs
#   `FERROGATE_ALLOWLIST_MAX_AGE_SECS` — maximum accepted allowlist age.
# @param ima_log
#   `FERROGATE_IMA_LOG` — override the IMA runtime-measurement log path. Linux
#   only.
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
  Optional[String[1]]             $repo_password          = undef,
  Optional[Integer[0]]            $repo_priority          = undef,
  String[1]                       $service_name           = 'mia',
  Boolean                         $manage_service         = true,
  Enum['running', 'stopped']      $service_ensure         = 'running',
  Boolean                         $service_enable         = true,
  Boolean                         $manage_user            = true,
  String[1]                       $user_name              = '_ferrogate',
  Stdlib::Absolutepath            $user_shell             = '/sbin/nologin',
  Optional[Stdlib::Absolutepath]  $config_dir             = undef,
  Boolean                         $manage_config_dir      = true,
  Boolean                         $manage_toml            = true,
  String[1]                       $rust_log               = 'info',
  Optional[String[1]]             $cmis_endpoint          = undef,
  Optional[String[1]]             $cmis_srv               = undef,
  Optional[String[1]]             $cmis_spki_pin          = undef,
  Optional[String[1]]             $helper_socket          = '/run/ferrogate/mia.sock',
  Optional[String[1]]             $helper_socket_mode     = '660',
  Optional[Stdlib::Absolutepath]  $allowlist_path         = undef,
  Optional[Stdlib::Absolutepath]  $allowlist_key          = undef,
  Optional[Integer[1]]            $allowlist_max_age_secs = undef,
  Optional[Stdlib::Absolutepath]  $ima_log                = undef,
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
  } else {
    $_owner            = 'root'
    $_group            = 'root'
    $_dir_mode         = '0755'
    $_file_mode        = '0640'
    $_service_provider = 'systemd'
    $_package_provider = undef
  }

  # The helper-API default (`/run/ferrogate/mia.sock`) is a Unix socket; on
  # Windows the helper API is a named pipe, so drop the inapplicable Unix
  # default there (an explicit value is still honoured).
  if $_windows and $helper_socket == '/run/ferrogate/mia.sock' {
    $_helper_socket = undef
  } else {
    $_helper_socket = $helper_socket
  }

  # --- Optional custom package repository (off by default) ------------------
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
        chocolateysource { 'ferrogate-mia':
          ensure   => present,
          location => $repo_baseurl,
          user     => $repo_user,
          password => $repo_password,
          priority => $repo_priority,
        }
        if $manage_package {
          Chocolateysource['ferrogate-mia'] -> Package[$package_name]
        }
      }
      default: {
        fail("ferrogate::mia: manage_repo is not supported on os family '${facts['os']['family']}'.")
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
      ensure   => $package_ensure,
      provider => $_package_provider,
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
        'allowlist_path'         => $allowlist_path,
        'allowlist_key'          => $allowlist_key,
        'allowlist_max_age_secs' => $allowlist_max_age_secs,
        'ima_log'                => $ima_log,
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
      group   => $_group,
      mode    => $_file_mode,
      content => epp('ferrogate/mia-client.toml.epp', {
          'rust_log'               => $rust_log,
          'cmis_endpoint'          => $cmis_endpoint,
          'cmis_srv'               => $cmis_srv,
          'cmis_spki_pin'          => $cmis_spki_pin,
          'helper_socket'          => $_helper_socket,
          'helper_socket_mode'     => $helper_socket_mode,
          'allowlist_path'         => $allowlist_path,
          'allowlist_key'          => $allowlist_key,
          'allowlist_max_age_secs' => $allowlist_max_age_secs,
          'ima_log'                => $ima_log,
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
  }
}
