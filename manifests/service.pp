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
    # Optional bind mounts: the listener TLS material (cmis_tls_enable) and the
    # managed inter-node peer CA/leaf (multi-node managed-CA path). Either may be
    # present independently.
    $_tls_volume = $ferrogate::_cmis_tls_enable ? {
      true    => ["${ferrogate::_tls_dir}:${ferrogate::_tls_container_dir}"],
      default => [],
    }
    $_peer_volume = $ferrogate::_peer_ca_active ? {
      true    => ["${ferrogate::_peer_tls_dir}:${ferrogate::_peer_tls_container_dir}"],
      default => [],
    }
    $_cmis_volumes = $_cmis_state_volumes + $_tls_volume + $_peer_volume

    # Networking depends on the cluster topology:
    #
    # * Single-node: rootless `pasta` (the runtime default). CMIS binds its Raft
    #   and API transports on loopback (CMIS_RAFT_LISTEN unset), so only the gRPC
    #   port is published; raft/api stay private.
    #
    # * Multi-node (F05 HA): host networking. CMIS binds CMIS_RAFT_LISTEN
    #   (0.0.0.0) on a routable interface so peers can reach it, and hiqlite's
    #   leader dials its own advertised FQDN — rootless pasta cannot hairpin a
    #   published port back into its own container, so the node would never reach
    #   itself. Sharing the host network namespace lets the node bind the real
    #   host address and reach itself over it. Ports bind directly on the host
    #   then, so PublishPort is redundant.
    $_cmis_grpc_port = "${ferrogate::_cmis_port}:${ferrogate::_cmis_container_port}"
    if $ferrogate::_cmis_cluster_multinode {
      $_cmis_ports    = []
      $_cmis_networks = ['host']
    } else {
      $_cmis_ports    = [$_cmis_grpc_port]
      $_cmis_networks = []
    }

    ferrogate::instance { 'cmis':
      command  => 'cmis',
      env_file => "${config_dir}/cmis.env",
      volumes  => $_cmis_volumes,
      ports    => $_cmis_ports,
      devices  => [],
      networks => $_cmis_networks,
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
