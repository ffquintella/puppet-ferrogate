# @summary Install and configure the FerroGate MIA host agent from its OS package.
#
# Standalone, self-contained class for the **Machine Identity Agent (MIA)**
# *client*. Unlike the container-based `mia_enable` switch on the main
# `ferrogate` class (which runs MIA inside the server image — see its caveats),
# this class deploys MIA the way FerroGate actually ships it: as a native host
# OS package (`ferrogate-mia`) that drops a static `/usr/bin/mia` binary, a
# `mia` systemd unit, and the config templates under `/etc/ferrogate/`.
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
# @example With a signed local-caller allowlist for the helper API
#   class { 'ferrogate::mia':
#     cmis_endpoint  => 'https://cmis.example.com:8443',
#     cmis_spki_pin  => '5f2e...c4',
#     allowlist_path => '/etc/ferrogate/allowlist.cbor',
#     allowlist_key  => '/etc/ferrogate/allowlist.pub',
#   }
#
# The package must be reachable through the node's existing package repositories
# (this class installs it but does not configure a repo, mirroring how the
# server class treats the container runtime). MIA is configured entirely through
# the systemd `EnvironmentFile` this class renders at `<config_dir>/mia.env`;
# every `FERROGATE_*` / `RUST_LOG` variable overrides the optional TOML file.
#
# @param package_name
#   Name of the MIA OS package.
# @param package_ensure
#   `ensure` for the package (`'installed'`, a pinned version, `'latest'`, …).
# @param manage_package
#   Whether to manage the package. Set `false` if another module owns it.
# @param manage_repo
#   Whether to add a custom `ferrogate-mia` package repository before installing.
#   **Defaults to `false`** — the package is assumed reachable through the node's
#   existing repositories. When `true`, `repo_baseurl` is required and a repo is
#   declared (a `yumrepo` on the RedHat family, an apt source list on the Debian
#   family) and ordered before the package.
# @param repo_baseurl
#   Base URL of the custom repository. Required when `manage_repo` is `true`.
#   RedHat: the `yumrepo` `baseurl`. Debian: the `deb` line URI.
# @param repo_descr
#   Human-readable repository name/description.
# @param repo_gpgcheck
#   Whether to verify package signatures against `repo_gpgkey`.
# @param repo_gpgkey
#   GPG key for signature verification. RedHat: a `gpgkey` URL or local path.
#   Debian: a local keyring file path used as the source's `signed-by`. When
#   `undef`, signing is not enforced for the added source.
# @param repo_release
#   Debian only — the suite/codename for the `deb` line. Defaults to the node's
#   distro codename fact; required when that fact is absent.
# @param repo_components
#   Debian only — the components for the `deb` line.
# @param service_name
#   Name of the systemd unit shipped by the package.
# @param manage_service
#   Whether to manage the service resource.
# @param service_ensure
#   Run state of the service (`'running'` / `'stopped'`).
# @param service_enable
#   Whether the service starts at boot.
# @param config_dir
#   Directory holding the MIA configuration. The package ships it; managed here
#   so the env file has a parent on a fresh node.
# @param manage_config_dir
#   Whether to manage `config_dir` as a directory.
# @param rust_log
#   `RUST_LOG` tracing filter for the agent.
# @param cmis_endpoint
#   `FERROGATE_CMIS_ENDPOINT` — the CMIS server URL. An `https://` URL is dialed
#   over hybrid-PQC TLS and authenticated by SPKI pin (see `cmis_spki_pin`);
#   `http://` is plaintext bring-up only.
# @param cmis_spki_pin
#   `FERROGATE_CMIS_SPKI_PIN` — the accepted CMIS SPKI pin (lowercase-hex
#   SHA-384). The server class publishes this value at
#   `<config_dir>/cmis.spki-pin.txt` on the CMIS node.
# @param helper_socket
#   `FERROGATE_HELPER_SOCKET` — path to the local helper-API Unix socket. Its
#   presence is what *enables* the helper API; with none set MIA logs a banner
#   and exits, so this defaults to the documented `/run/ferrogate/mia.sock`
#   (systemd provisions `/run/ferrogate`). Set to `undef` to leave it unset.
# @param helper_socket_mode
#   `FERROGATE_HELPER_SOCKET_MODE` — octal mode (as a string) for the helper
#   socket.
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
#   `FERROGATE_IMA_LOG` — override the IMA runtime-measurement log path.
# @param seccomp
#   `FERROGATE_SECCOMP` — seccomp mode for staged rollout: `'enforce'`
#   (default in the agent), `'audit'` (log violations) or `'off'`. Leave `undef`
#   to take the agent default.
# @param require_ima
#   Maps to `FERROGATE_REQUIRE_IMA`. `false` emits `FERROGATE_REQUIRE_IMA=0`
#   (do not require enforced IMA — dev/CI only); `true` emits `1`. Leave `undef`
#   to take the agent default (require IMA).
# @param skip_hardening
#   When `true`, set `FERROGATE_SKIP_HARDENING=1` to disable the whole hardening
#   profile. **Development only** — never in production.
# @param run_as_uid
#   `FERROGATE_RUN_AS_UID` — drop to this UID instead of resolving `_ferrogate`.
# @param run_as_gid
#   `FERROGATE_RUN_AS_GID` — drop to this GID instead of resolving `_ferrogate`.
# @param extra_env
#   Extra environment variables merged verbatim into the env file.
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
  String[1]                       $service_name           = 'mia',
  Boolean                         $manage_service         = true,
  Enum['running', 'stopped']      $service_ensure         = 'running',
  Boolean                         $service_enable         = true,
  Stdlib::Absolutepath            $config_dir             = '/etc/ferrogate',
  Boolean                         $manage_config_dir      = true,
  String[1]                       $rust_log               = 'info',
  Optional[String[1]]             $cmis_endpoint          = undef,
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

  $env_file = "${config_dir}/mia.env"

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
      default: {
        fail("ferrogate::mia: manage_repo is not supported on os family '${facts['os']['family']}'.")
      }
    }
  }

  if $manage_package {
    package { $package_name:
      ensure => $package_ensure,
    }
  }

  if $manage_config_dir {
    file { $config_dir:
      ensure => directory,
      owner  => 'root',
      group  => 'root',
      mode   => '0755',
    }
  }

  # systemd EnvironmentFile read by the shipped `mia` unit
  # (EnvironmentFile=-/etc/ferrogate/mia.env). Env vars override the optional
  # TOML, so this single file is the authoritative, unattended-provisioning
  # configuration surface.
  file { $env_file:
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0640',
    content => epp('ferrogate/mia-client.env.epp', {
        'rust_log'               => $rust_log,
        'cmis_endpoint'          => $cmis_endpoint,
        'cmis_spki_pin'          => $cmis_spki_pin,
        'helper_socket'          => $helper_socket,
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

  if $manage_config_dir {
    File[$config_dir] -> File[$env_file]
  }
  if $manage_package {
    Package[$package_name] -> File[$env_file]
  }

  if $manage_service {
    service { $service_name:
      ensure    => $service_ensure ? { 'running' => 'running', default => 'stopped' },
      enable    => $service_enable,
      provider  => 'systemd',
      subscribe => File[$env_file],
    }
    if $manage_package {
      Package[$package_name] -> Service[$service_name]
    }
  }
}
