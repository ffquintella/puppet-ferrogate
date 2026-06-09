# @summary Deploy FerroGate (CMIS and/or MIA) as rootless containers.
#
# Installs and runs the FerroGate machine-identity services from a container
# image, managed by systemd. When the chosen runtime is **podman** the services
# are described as rootless [Quadlet](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)
# `.container` units owned by a dedicated unprivileged user; when it is
# **docker** a plain system `systemd` unit wraps `docker run`. SELinux is
# configured so the bind-mounted host directories are reachable by the
# container.
#
# On-disk layout builds on the {ffquintella-baseapp} module: every FerroGate
# directory lives under the baseapp roots
# (`/srv/application-{config,data,logs}`) below a `ferrogate` sub-directory and,
# optionally, an *environment variant* sub-directory (empty by default).
#
#   /srv/application-config/ferrogate[/<app_environment>]
#   /srv/application-data/ferrogate[/<app_environment>]/audit
#   /srv/application-logs/ferrogate[/<app_environment>]
#
# @param runtime
#   Container runtime to use. `'auto'` resolves to the
#   `$facts['ferrogate_container_runtime']` fact (podman preferred over docker).
# @param manage_runtime
#   Whether to install the selected runtime package.
# @param registry
#   Optional registry host (and namespace) the image is pulled from, e.g.
#   `'ghcr.io/felipe-quintella'`. When `undef`/empty the bare
#   `<image_name>:<image_tag>` reference is used.
# @param image_name
#   Image repository name.
# @param image_tag
#   Image tag to deploy.
# @param pull_image
#   Whether to pull the image during the Puppet run.
# @param app_environment
#   Environment-variant sub-directory appended after `ferrogate` in every
#   baseapp root. Empty by default (no extra level).
# @param user
#   Dedicated unprivileged user that owns the directories and (for podman) runs
#   the rootless containers.
# @param group
#   Primary group for the dedicated user.
# @param uid
#   UID for the dedicated user. Matches the image's built-in user (10001).
# @param gid
#   GID for the dedicated group.
# @param manage_user
#   Whether to manage the dedicated user/group. For podman this also creates a
#   companion `<user>-pod` account whose uid/gid is the *mapped* id the rootless
#   container's internal user resolves to (`subid_start + uid - 1`); the
#   bind-mounted log/audit volumes are owned by it so the non-root container can
#   write them. (Rootless podman remaps the container's internal uid to a
#   subordinate id, so the login user — which only owns container id 0 — cannot
#   own the volumes; `keep-id`, which would avoid the remap, is broken on
#   podman 5.x + EL10/UEK.)
# @param manage_subids
#   Whether to register the dedicated user's rootless subordinate UID/GID range
#   (`/etc/subuid`, `/etc/subgid`) through `baseapp::subid`. **Defaults to
#   `true`.** baseapp owns those files as concat targets, so every rootless app
#   on the node (e.g. ferrogate + bastionvault) contributes one fragment and
#   they stop fighting over the files. Set `false` if an operator or another
#   module manages the ranges. Ignored for the docker runtime.
#
#   **Single owner:** baseapp must be the only manager of `/etc/subuid` /
#   `/etc/subgid`. If the `puppet/podman` module is also on the node, leave its
#   `manage_subuid => false` (the default) so it does not declare a competing
#   `Concat['/etc/subuid']`.
# @param subid_start
#   First subordinate id for the dedicated user. Defaults to `uid * 65536`, a
#   deterministic per-user block that does not overlap other users' ranges.
# @param subid_count
#   Size of the subordinate id block. Defaults to 65536.
# @param manage_selinux
#   Whether to apply SELinux configuration (no-op when SELinux is disabled).
# @param selinux_relabel
#   Volume relabel mode appended to bind mounts: `'Z'` (private),
#   `'z'` (shared) or `'none'`.
# @param rust_log
#   Value of the `RUST_LOG` tracing filter passed to every service.
# @param cmis_enable
#   Deploy the CMIS (Central Machine Identity Service) instance.
# @param cmis_listen
#   `CMIS_LISTEN` socket address inside the container.
# @param cmis_port
#   Host port published for CMIS (mapped to `cmis_container_port`).
# @param cmis_container_port
#   Container-side port CMIS listens on. Must match the port in `cmis_listen`.
# @param cmis_tls_enable
#   Terminate **hybrid-PQC TLS** (TLS 1.3, `X25519MLKEM768`-only) on the CMIS
#   listener. When `true` (the default) the module sets `CMIS_TLS_CERT` /
#   `CMIS_TLS_KEY` for the container and ensures a certificate exists (supplied
#   or generated — see `cmis_tls_cert`/`cmis_tls_manage_cert`). When `false`
#   CMIS runs the **plaintext bring-up server** — dev only; never in production.
#   FerroGate authenticates the server by **SPKI pin**, not a CA chain, so a
#   self-signed certificate is fine; the module also publishes the pin (see
#   below) for configuring MIA clients.
#
#   **Caveat:** the in-container operator CLI (`/usr/local/bin/ferrogate`) is a
#   plaintext gRPC client today. With TLS on, the wrapper points it at an
#   `https://` loopback endpoint; it works only against a `ferrogate` CLI build
#   that speaks the F01 hybrid-PQC transport. On an older CLI, run operator
#   commands against a node with TLS off, or use a TLS-aware client.
# @param cmis_tls_cert
#   PEM certificate chain for the CMIS listener (end-entity first, then any
#   intermediates), as a string. When set, `cmis_tls_key` must also be set and
#   the pair is written to disk verbatim (no generation). When `undef` and
#   `cmis_tls_manage_cert` is `true`, a self-signed certificate is generated.
# @param cmis_tls_key
#   PEM private key (PKCS#8, PKCS#1 or SEC1) matching `cmis_tls_cert`, as a
#   string. Set both `cmis_tls_cert` and `cmis_tls_key` together, or neither.
# @param cmis_tls_manage_cert
#   When TLS is enabled and no certificate is supplied, generate a self-signed
#   P-384 certificate with OpenSSL on the node (idempotent — only created if the
#   cert file is absent). Set `false` to require an operator-supplied cert and
#   fail the run if none is present. Requires `openssl` on the host. Ignored
#   when `cmis_tls_cert`/`cmis_tls_key` are supplied.
# @param cmis_tls_cert_cn
#   Common Name (subject) for the generated self-signed certificate. Defaults to
#   the node FQDN fact, falling back to `cmis.ferrogate.internal`. The hostname
#   is irrelevant to trust (SPKI pinning) — it is used only for SNI/routing.
# @param cmis_tls_cert_days
#   Validity in days for the generated self-signed certificate. Ignored for a
#   supplied certificate.
# @param mia_enable
#   Deploy the MIA (Machine Identity Agent) as a container. **Defaults to
#   `false`**: the standard FerroGate image is CMIS-only — it ships the `cmis`
#   server and the `ferrogate` CLI but no `mia` binary, and its entrypoint
#   expects MIA to be installed on the host from its OS package rather than run
#   in a container. Only enable this against an image that actually bundles
#   `mia`, on a host prepared for the MIA hardening profile.
# @param mia_tpm_device
#   Host TPM resource-manager device handed to the MIA container.
# @param mia_skip_hardening
#   Set `FERROGATE_SKIP_HARDENING=1` for MIA. The host-hardening profile
#   (enforced IMA, seccomp install, privilege drop) cannot be satisfied inside a
#   generic container, so this defaults to `true`. Set `false` only on a host
#   prepared for the full MIA hardening profile.
# @param extra_env
#   Extra environment variables merged into every instance's env file.
#
# @example Defaults — deploy CMIS with podman, rootless (MIA off; see mia_enable)
#   include ferrogate
#
# @example Pull from a private registry, pin a tag, use docker
#   class { 'ferrogate':
#     runtime    => 'docker',
#     registry   => 'registry.example.com/fgv',
#     image_tag  => '1.4.0',
#   }
#
# @example Per-environment deployment under /srv/.../ferrogate/staging
#   class { 'ferrogate':
#     app_environment => 'staging',
#   }
class ferrogate (
  Enum['auto', 'podman', 'docker'] $runtime            = 'auto',
  Boolean                          $manage_runtime     = true,
  Optional[String[1]]              $registry           = undef,
  String[1]                        $image_name         = 'ferrogate',
  String[1]                        $image_tag          = 'latest',
  Boolean                          $pull_image         = true,
  String                           $app_environment    = '',
  String[1]                        $user               = 'ferrogate',
  String[1]                        $group              = 'ferrogate',
  Integer[0]                       $uid                = 10001,
  Integer[0]                       $gid                = 10001,
  Boolean                          $manage_user        = true,
  Boolean                          $manage_subids      = true,
  Optional[Integer[0]]             $subid_start        = undef,
  Integer[1]                       $subid_count        = 65536,
  Boolean                          $manage_selinux     = true,
  Enum['Z', 'z', 'none']           $selinux_relabel    = 'Z',
  String[1]                        $rust_log           = 'info',
  Boolean                          $cmis_enable        = true,
  String[1]                        $cmis_listen        = '0.0.0.0:8443',
  Stdlib::Port                     $cmis_port          = 8443,
  Stdlib::Port                     $cmis_container_port = 8443,
  Boolean                          $cmis_tls_enable    = true,
  Optional[String[1]]              $cmis_tls_cert      = undef,
  Optional[String[1]]              $cmis_tls_key       = undef,
  Boolean                          $cmis_tls_manage_cert = true,
  Optional[String[1]]              $cmis_tls_cert_cn   = undef,
  Integer[1]                       $cmis_tls_cert_days = 3650,
  Boolean                          $mia_enable         = false,
  Stdlib::Absolutepath             $mia_tpm_device     = '/dev/tpmrm0',
  Boolean                          $mia_skip_hardening = true,
  Hash[String[1], String]          $extra_env          = {},
) {
  # --- Resolve the effective container runtime ------------------------------
  $_runtime = $runtime ? {
    'auto'  => $facts['ferrogate_container_runtime'],
    default => $runtime,
  }
  if !$_runtime {
    fail('ferrogate: no container runtime found; install podman or docker, or set $runtime explicitly.')
  }

  # --- Validate the CMIS TLS configuration ----------------------------------
  if $cmis_enable and $cmis_tls_enable {
    if ($cmis_tls_cert and !$cmis_tls_key) or ($cmis_tls_key and !$cmis_tls_cert) {
      fail('ferrogate: set both cmis_tls_cert and cmis_tls_key together, or neither.')
    }
    if !$cmis_tls_cert and !$cmis_tls_key and !$cmis_tls_manage_cert {
      fail('ferrogate: cmis_tls_enable is true but no certificate was supplied and cmis_tls_manage_cert is false.')
    }
  }

  # Resolve the subject CN for a generated self-signed certificate. Trust is by
  # SPKI pin, so the name only matters for SNI/routing — default to the FQDN.
  if $cmis_tls_cert_cn {
    $_cmis_tls_cert_cn = $cmis_tls_cert_cn
  } elsif $facts['networking'] and $facts['networking']['fqdn'] {
    $_cmis_tls_cert_cn = $facts['networking']['fqdn']
  } else {
    $_cmis_tls_cert_cn = 'cmis.ferrogate.internal'
  }

  # --- Resolve the image reference ------------------------------------------
  if $registry and $registry != '' {
    $_image = "${registry}/${image_name}:${image_tag}"
  } else {
    $_image = "${image_name}:${image_tag}"
  }

  # --- Compute the baseapp-rooted directory layout --------------------------
  # ferrogate + optional environment-variant sub-directory.
  $_suffix = $app_environment ? {
    ''      => 'ferrogate',
    default => "ferrogate/${app_environment}",
  }
  $config_dir = "/srv/application-config/${_suffix}"
  $data_dir   = "/srv/application-data/${_suffix}"
  $logs_dir   = "/srv/application-logs/${_suffix}"
  $audit_dir  = "${data_dir}/audit"

  # Re-export the parameters as body variables so the contained sub-classes can
  # read them as `$ferrogate::_<name>` (qualified class *parameters* are not
  # always resolvable cross-class in every evaluator; body variables are).
  $_user               = $user
  $_group              = $group
  $_uid                = $uid
  $_gid                = $gid
  $_manage_user        = $manage_user
  $_manage_subids      = $manage_subids
  $_subid_start        = $subid_start
  $_subid_count        = $subid_count
  $_pod_user           = "${user}-pod"
  $_pod_group          = "${group}-pod"
  $_manage_runtime     = $manage_runtime
  $_pull_image         = $pull_image
  $_manage_selinux     = $manage_selinux
  $_selinux_relabel    = $selinux_relabel
  $_rust_log           = $rust_log
  $_cmis_enable        = $cmis_enable
  $_cmis_listen        = $cmis_listen
  $_cmis_port          = $cmis_port
  $_cmis_container_port = $cmis_container_port
  $_cmis_tls_enable      = $cmis_tls_enable
  $_cmis_tls_cert        = $cmis_tls_cert
  $_cmis_tls_key         = $cmis_tls_key
  $_cmis_tls_manage_cert = $cmis_tls_manage_cert
  $_cmis_tls_cert_days   = $cmis_tls_cert_days
  # On-disk (host) and in-container paths for the TLS material. The cert/key
  # directory is bind-mounted into the CMIS container; the SPKI pin file is a
  # host-only convenience kept under the login-user-owned config root so
  # operators (and root) can read it to configure MIA pinning.
  $_tls_dir            = "${config_dir}/tls"
  $_tls_cert_file      = "${config_dir}/tls/cmis.crt"
  $_tls_key_file       = "${config_dir}/tls/cmis.key"
  $_tls_pin_file       = "${config_dir}/cmis.spki-pin.txt"
  $_tls_container_dir  = '/etc/ferrogate/tls'
  $_tls_container_cert = '/etc/ferrogate/tls/cmis.crt'
  $_tls_container_key  = '/etc/ferrogate/tls/cmis.key'
  $_mia_enable         = $mia_enable
  $_mia_tpm_device     = $mia_tpm_device
  $_mia_skip_hardening = $mia_skip_hardening
  $_extra_env          = $extra_env

  # The shared /srv/application-* roots stay root:root 0755 (baseapp defaults)
  # so every app user on the node can traverse to its own subdirectory. The
  # FerroGate-owned tree lives in the per-app subdirs that ferrogate::config
  # creates ($user-owned, 0750). Overriding the roots to ferrogate:ferrogate
  # 0750 here locked other apps (e.g. bastionvault) out of their own subdirs,
  # since the roots then had no traverse bit for "other".
  include baseapp

  class { 'ferrogate::install': }
  class { 'ferrogate::config': }
  class { 'ferrogate::selinux': }
  class { 'ferrogate::service': }

  contain baseapp
  contain ferrogate::install
  contain ferrogate::config
  contain ferrogate::selinux
  contain ferrogate::service

  # CMIS TLS material (cert/key placement or generation, plus the SPKI pin).
  # Only relevant when CMIS terminates TLS on this node.
  if $cmis_enable and $cmis_tls_enable {
    class { 'ferrogate::tls': }
    contain ferrogate::tls
  }

  # Host-side operator CLI wrapper. Only useful when CMIS is running, since the
  # `ferrogate` CLI is a gRPC client of CMIS.
  if $cmis_enable {
    class { 'ferrogate::cli': }
    contain ferrogate::cli
  }

  # baseapp now owns the shared /srv roots as root:root and no longer depends
  # on the ferrogate user, so it can run first. ferrogate::config creates the
  # per-app subdirs beneath those roots, so it must come after both baseapp
  # (roots exist) and install (ferrogate user exists).
  Class['baseapp']
  -> Class['ferrogate::install']
  -> Class['ferrogate::config']
  -> Class['ferrogate::selinux']
  -> Class['ferrogate::service']

  # The CMIS instance bind-mounts the TLS directory, so the cert/key must be in
  # place before the service starts. Slot the tls class between config (which
  # creates the config root it writes into) and service.
  if $cmis_enable and $cmis_tls_enable {
    Class['ferrogate::config']
    -> Class['ferrogate::tls']
    -> Class['ferrogate::service']
  }

  # The CLI wrapper is a static host script; writing it does not require the
  # container to be running. Order it after `install` (which creates the service
  # user the wrapper sudo's to) rather than after the whole `service` class, so a
  # container-start failure (e.g. an unsupported MIA image) cannot skip the
  # wrapper and the sudoers drop-in.
  if $cmis_enable {
    Class['ferrogate::install'] -> Class['ferrogate::cli']
  }
}
