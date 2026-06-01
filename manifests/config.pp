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
  $config_dir = $ferrogate::config_dir
  $data_dir   = $ferrogate::data_dir
  $logs_dir   = $ferrogate::logs_dir
  $audit_dir  = $ferrogate::audit_dir

  # --- Directory tree under the baseapp roots -------------------------------
  # /srv/application-config/ferrogate[/<env>]
  # /srv/application-data/ferrogate[/<env>]/audit
  # /srv/application-logs/ferrogate[/<env>]
  $_dirs = [$config_dir, $data_dir, $logs_dir, $audit_dir]

  file { $_dirs:
    ensure => directory,
    owner  => $user,
    group  => $group,
    mode   => '0750',
  }

  # --- Per-instance environment files ---------------------------------------
  if $ferrogate::_cmis_enable {
    file { "${config_dir}/cmis.env":
      ensure  => file,
      owner   => $user,
      group   => $group,
      mode    => '0640',
      content => epp('ferrogate/cmis.env.epp', {
          'rust_log'    => $ferrogate::_rust_log,
          'cmis_listen' => $ferrogate::_cmis_listen,
          'extra_env'   => $ferrogate::_extra_env,
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
