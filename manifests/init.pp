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
#   Whether to manage the dedicated user/group.
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
# @param mia_enable
#   Deploy the MIA (Machine Identity Agent) instance.
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
# @example Defaults — deploy both CMIS and MIA with podman, rootless
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
  Boolean                          $manage_selinux     = true,
  Enum['Z', 'z', 'none']           $selinux_relabel    = 'Z',
  String[1]                        $rust_log           = 'info',
  Boolean                          $cmis_enable        = true,
  String[1]                        $cmis_listen        = '0.0.0.0:8443',
  Stdlib::Port                     $cmis_port          = 8443,
  Stdlib::Port                     $cmis_container_port = 8443,
  Boolean                          $mia_enable         = true,
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
  $_manage_runtime     = $manage_runtime
  $_pull_image         = $pull_image
  $_manage_selinux     = $manage_selinux
  $_selinux_relabel    = $selinux_relabel
  $_rust_log           = $rust_log
  $_cmis_enable        = $cmis_enable
  $_cmis_listen        = $cmis_listen
  $_cmis_port          = $cmis_port
  $_cmis_container_port = $cmis_container_port
  $_mia_enable         = $mia_enable
  $_mia_tpm_device     = $mia_tpm_device
  $_mia_skip_hardening = $mia_skip_hardening
  $_extra_env          = $extra_env

  # Re-declare baseapp so the /srv roots are owned by the FerroGate user.
  class { 'baseapp':
    owner => $user,
    group => $group,
    mode  => '0750',
  }

  class { 'ferrogate::install': }
  class { 'ferrogate::config': }
  class { 'ferrogate::selinux': }
  class { 'ferrogate::service': }

  contain baseapp
  contain ferrogate::install
  contain ferrogate::config
  contain ferrogate::selinux
  contain ferrogate::service

  # ferrogate::install must run *before* baseapp: baseapp chowns the
  # /srv/application-* roots to the ferrogate user/group, so it auto-requires
  # User/Group[ferrogate] — which install creates. Ordering baseapp first would
  # form a dependency cycle (baseapp's File -> needs install's Group -> install
  # ordered after baseapp).
  Class['ferrogate::install']
  -> Class['baseapp']
  -> Class['ferrogate::config']
  -> Class['ferrogate::selinux']
  -> Class['ferrogate::service']
}
