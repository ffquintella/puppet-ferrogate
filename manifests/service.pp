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
  $raft_dir   = $ferrogate::raft_dir
  $issuer_dir = $ferrogate::issuer_dir
  $config_dir = $ferrogate::config_dir

  # CMIS: gRPC server. Mounts the log + audit (WORM) volumes, the raft store
  # (allowlists/proposals/SVIDs — CMIS_RAFT_DIR default) and the issuer key
  # (CMIS_ISSUER_KEY default), publishes 8443. Without the raft and issuer
  # mounts that state lands on the container's ephemeral layer (or an
  # anonymous volume) and is silently wiped on every image upgrade.
  # When TLS terminates here, also bind-mount the cert/key directory that
  # ferrogate::tls populated (read by the container via CMIS_TLS_CERT/_KEY).
  if $ferrogate::_cmis_enable {
    $_cmis_state_volumes = [
      "${logs_dir}:/opt/ferrogate/logs",
      "${audit_dir}:/var/lib/ferrogate/audit",
      "${raft_dir}:/var/lib/ferrogate/raft",
      "${issuer_dir}:/var/lib/ferrogate/issuer",
    ]
    if $ferrogate::_cmis_tls_enable {
      $_cmis_volumes = $_cmis_state_volumes + [
        "${ferrogate::_tls_dir}:${ferrogate::_tls_container_dir}",
      ]
    } else {
      $_cmis_volumes = $_cmis_state_volumes
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
