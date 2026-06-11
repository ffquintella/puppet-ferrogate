# @summary Create the FerroGate directory layout and per-instance env files.
#
# Private class — managed via the main `ferrogate` class. Lays out the
# `ferrogate` (and optional environment-variant) directories under the baseapp
# roots and renders the environment files consumed by each instance.
#
# @api private
class ferrogate::config {
  assert_private()

  $user       = $ferrogate::_user
  $group      = $ferrogate::_group
  $uid        = $ferrogate::_uid
  $gid        = $ferrogate::_gid
  $runtime    = $ferrogate::_runtime
  $config_dir = $ferrogate::config_dir
  $data_dir   = $ferrogate::data_dir
  $logs_dir   = $ferrogate::logs_dir
  $audit_dir  = $ferrogate::audit_dir
  $raft_dir   = $ferrogate::raft_dir
  $issuer_dir = $ferrogate::issuer_dir

  # The bind-mounted volumes (logs, audit) are written *from inside* the
  # container by its non-root user. Under rootless podman that internal id is
  # remapped to a host subordinate id (container id C -> subid_start + (C - 1)),
  # so the volumes must be owned by that mapped id rather than the login user
  # (which only owns container id 0). Compute it locally — the test evaluator
  # does not resolve a function default computed across the class boundary.
  # Under docker there is no remap: the container runs as the login uid directly.
  if $runtime == 'podman' {
    $_subid_start = $ferrogate::_subid_start ? {
      undef   => $uid * 65536,
      default => $ferrogate::_subid_start,
    }
    $_vol_owner = $_subid_start + $uid - 1
    $_vol_group = $_subid_start + $gid - 1
  } else {
    $_vol_owner = $user
    $_vol_group = $group
  }

  # --- Directory tree under the baseapp roots -------------------------------
  # /srv/application-config/ferrogate[/<env>]      (login-user owned)
  # /srv/application-data/ferrogate[/<env>]        (login-user owned)
  # /srv/application-data/ferrogate[/<env>]/audit  (container-mapped owner)
  # /srv/application-data/ferrogate[/<env>]/raft   (container-mapped owner)
  # /srv/application-data/ferrogate[/<env>]/issuer (container-mapped owner)
  # /srv/application-logs/ferrogate[/<env>]        (container-mapped owner)
  file { [$config_dir, $data_dir]:
    ensure => directory,
    owner  => $user,
    group  => $group,
    mode   => '0750',
  }

  # Volumes mounted into the container — owned by the (possibly remapped) id the
  # container process writes as. See the comment above.
  file { [$logs_dir, $audit_dir, $raft_dir, $issuer_dir]:
    ensure => directory,
    owner  => $_vol_owner,
    group  => $_vol_group,
    mode   => '0750',
  }

  # --- Per-instance environment files ---------------------------------------
  if $ferrogate::_cmis_enable {
    # In-container TLS paths, set only when CMIS terminates TLS (empty strings
    # leave CMIS_TLS_CERT / CMIS_TLS_KEY unset ⇒ plaintext bring-up server).
    if $ferrogate::_cmis_tls_enable {
      $tls_cert = $ferrogate::_tls_container_cert
      $tls_key  = $ferrogate::_tls_container_key
    } else {
      $tls_cert = ''
      $tls_key  = ''
    }

    file { "${config_dir}/cmis.env":
      ensure  => file,
      owner   => $user,
      group   => $group,
      mode    => '0640',
      content => epp('ferrogate/cmis.env.epp', {
          'rust_log'            => $ferrogate::_rust_log,
          'cmis_listen'         => $ferrogate::_cmis_listen,
          'tls_cert'            => $tls_cert,
          'tls_key'             => $tls_key,
          'allowlist_proposals' => $ferrogate::_cmis_allowlist_proposals,
          'ha_env'              => $ferrogate::_cmis_ha_env,
          'extra_env'           => $ferrogate::_extra_env,
      }),
      require => File[$config_dir],
    }
  }

  if $ferrogate::_mia_enable {
    file { "${config_dir}/mia.env":
      ensure  => file,
      owner   => $user,
      group   => $group,
      mode    => '0640',
      content => epp('ferrogate/mia.env.epp', {
          'rust_log'       => $ferrogate::_rust_log,
          'skip_hardening' => $ferrogate::_mia_skip_hardening,
          'extra_env'      => $ferrogate::_extra_env,
      }),
      require => File[$config_dir],
    }
  }
}
