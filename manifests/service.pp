# @summary Declare the enabled FerroGate service instances.
#
# Private class — managed via the main `ferrogate` class. Maps the high-level
# `cmis_enable`/`mia_enable` switches onto `ferrogate::instance` resources,
# wiring in the per-service volumes, published ports and devices.
#
# @api private
class ferrogate::service {
  assert_private()

  $logs_dir   = $ferrogate::logs_dir
  $audit_dir  = $ferrogate::audit_dir
  $config_dir = $ferrogate::config_dir

  # CMIS: gRPC server. Mounts the log + audit (WORM) volumes, publishes 8443.
  # When TLS terminates here, also bind-mount the cert/key directory that
  # ferrogate::tls populated (read by the container via CMIS_TLS_CERT/_KEY).
  if $ferrogate::_cmis_enable {
    if $ferrogate::_cmis_tls_enable {
      $_cmis_volumes = [
        "${logs_dir}:/opt/ferrogate/logs",
        "${audit_dir}:/var/lib/ferrogate/audit",
        "${ferrogate::_tls_dir}:${ferrogate::_tls_container_dir}",
      ]
    } else {
      $_cmis_volumes = [
        "${logs_dir}:/opt/ferrogate/logs",
        "${audit_dir}:/var/lib/ferrogate/audit",
      ]
    }

    ferrogate::instance { 'cmis':
      command  => 'cmis',
      env_file => "${config_dir}/cmis.env",
      volumes  => $_cmis_volumes,
      ports    => ["${ferrogate::_cmis_port}:${ferrogate::_cmis_container_port}"],
      devices  => [],
    }
  }

  # MIA: host agent. Needs the TPM device and a log volume.
  if $ferrogate::_mia_enable {
    ferrogate::instance { 'mia':
      command  => 'mia',
      env_file => "${config_dir}/mia.env",
      volumes  => ["${logs_dir}:/opt/ferrogate/logs"],
      ports    => [],
      devices  => [$ferrogate::_mia_tpm_device],
    }
  }
}
