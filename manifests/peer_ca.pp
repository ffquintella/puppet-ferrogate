# @summary Provision the CMIS inter-node (peer) transport CA and this node's leaf.
#
# Private class — managed via the main `ferrogate` class, and only declared for a
# multi-node CMIS cluster that wants peer TLS (`cmis_peer_tls`), has CA
# management enabled (`cmis_peer_ca_manage`), and did not supply its own leaf
# pair (`cmis_peer_tls_cert`/`_key`).
#
# **Why this exists.** hiqlite's split-brain / cluster-metrics client validates
# the peer's TLS certificate with rustls' *platform verifier* — the OS trust
# store *inside the CMIS container* — rather than the shared-secret handshake the
# Raft transport itself uses. A bare self-signed `CMIS_PEER_TLS=1` certificate
# therefore fails that probe with `UnknownIssuer`, leaving the cluster's
# split-brain safety check blind even though Raft replicates. This class issues
# each node's leaf from a CA and tells the container to trust that CA via
# `SSL_CERT_FILE` (set in `cmis.env` by the main class), so the probe succeeds.
#
# It lays out a host-side `peer-tls/` directory under the config root holding the
# CA certificate (`ca.crt`) and this node's leaf certificate (`peer.crt`) and key
# (`peer.key`); that directory is bind-mounted into the container by
# `ferrogate::service` at `/etc/ferrogate/peer-tls`. The CA *private* key
# (`peer-ca.key`) and the CSR/serial scratch files stay one level up under the
# config root and are **never** mounted into the container.
#
# The CA is either:
#   * **supplied** — when `cmis_peer_ca_cert`/`cmis_peer_ca_key` are set, written
#     verbatim. This is how a real multi-node fleet shares **one** CA: hand every
#     node the same CA cert+key (the key via eyaml) so each node's leaf chains to
#     a CA all the others trust; or
#   * **generated** — a self-signed P-384 CA produced with OpenSSL when none is
#     supplied. A locally generated CA is only mutually trusted on a single-node
#     cluster (the node dials itself); to use it across hosts, distribute the
#     generated `ca.crt`/`peer-ca.key` to every peer.
#
# The leaf is always issued locally from the CA, with the node FQDN as the
# subject CN and `subjectAltName` (rustls matches the dialed name against the
# SAN). Requires OpenSSL ≥ 3.0 on the host (`-copy_extensions`).
#
# @api private
class ferrogate::peer_ca {
  assert_private()

  $user        = $ferrogate::_user
  $group       = $ferrogate::_group
  $uid         = $ferrogate::_uid
  $gid         = $ferrogate::_gid
  $runtime     = $ferrogate::_runtime
  $config_dir  = $ferrogate::config_dir

  $peer_dir     = $ferrogate::_peer_tls_dir
  $ca_cert_file = $ferrogate::_peer_ca_cert_file
  $ca_key_file  = $ferrogate::_peer_ca_key_file
  $cert_file    = $ferrogate::_peer_cert_file
  $key_file     = $ferrogate::_peer_key_file
  $csr_file     = $ferrogate::_peer_csr_file
  $serial_file  = $ferrogate::_peer_serial_file
  $ca_cert      = $ferrogate::_cmis_peer_ca_cert
  $ca_key       = $ferrogate::_cmis_peer_ca_key
  $ca_days      = $ferrogate::_cmis_peer_ca_days
  $ca_cn        = $ferrogate::_peer_ca_cn
  $cert_cn      = $ferrogate::_peer_cert_cn
  $san          = $ferrogate::_peer_san

  # The cert/key are read *from inside* the container by its non-root user. Under
  # rootless podman that internal id is remapped to a host subordinate id
  # (container id C -> subid_start + (C - 1)); under docker there is no remap.
  # Mirrors the volume-owner computation in ferrogate::config / ferrogate::tls
  # (recomputed locally because the test evaluator does not resolve it across the
  # class boundary).
  if $runtime == 'podman' {
    $_subid_start = $ferrogate::_subid_start ? {
      undef   => $uid * 65536,
      default => $ferrogate::_subid_start,
    }
    $_owner = $_subid_start + $uid - 1
    $_grp   = $_subid_start + $gid - 1
  } else {
    $_owner = $user
    $_grp   = $group
  }

  $_ca_supplied = ($ca_cert != undef and $ca_key != undef)

  # --- peer-tls/ directory (bind-mounted into the container) ----------------
  file { $peer_dir:
    ensure  => directory,
    owner   => $_owner,
    group   => $_grp,
    mode    => '0750',
    require => File[$config_dir],
  }

  # --- CA certificate + key: supplied verbatim, or generated ----------------
  if $_ca_supplied {
    # CA private key stays host-only (config root, not the mounted dir).
    file { $ca_key_file:
      ensure  => file,
      owner   => $user,
      group   => $group,
      mode    => '0600',
      content => $ca_key,
      require => File[$config_dir],
    }
    # CA certificate is the in-container trust anchor (SSL_CERT_FILE), so it
    # lives in the mounted dir and is owned by the container-mapped id.
    file { $ca_cert_file:
      ensure  => file,
      owner   => $_owner,
      group   => $_grp,
      mode    => '0644',
      content => $ca_cert,
      require => File[$peer_dir],
    }
  } else {
    # Generate the CA key once (host-only) — never regenerated implicitly, since
    # every leaf and every pinned/trusting peer chains to it.
    exec { 'ferrogate-peer-ca-genkey':
      command  => "openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 -out ${ca_key_file}",
      path     => ['/usr/bin', '/bin'],
      provider => 'shell',
      creates  => $ca_key_file,
      require  => File[$config_dir],
    }
    # Self-sign the CA certificate from that key (CA basic constraints + key
    # usage). Removing just ca.crt re-issues from the same key.
    exec { 'ferrogate-peer-ca-gencert':
      command  => "openssl req -x509 -key ${ca_key_file} -out ${ca_cert_file} -days ${ca_days} -subj '/CN=${ca_cn}' -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' -addext 'keyUsage=critical,keyCertSign,cRLSign'", # lint:ignore:140chars
      path     => ['/usr/bin', '/bin'],
      provider => 'shell',
      creates  => $ca_cert_file,
      require  => [File[$peer_dir], Exec['ferrogate-peer-ca-genkey']],
    }
    file { $ca_key_file:
      ensure  => file,
      owner   => $user,
      group   => $group,
      mode    => '0600',
      require => Exec['ferrogate-peer-ca-genkey'],
    }
    file { $ca_cert_file:
      ensure  => file,
      owner   => $_owner,
      group   => $_grp,
      mode    => '0644',
      require => Exec['ferrogate-peer-ca-gencert'],
    }
  }

  # --- This node's leaf key + certificate, signed by the CA -----------------
  # The leaf key is generated once (idempotent); the certificate is issued from
  # the CA with the node FQDN as CN and a matching subjectAltName (rustls checks
  # the dialed name against the SAN). `-copy_extensions copyall` carries the SAN
  # from the CSR onto the issued cert (OpenSSL ≥ 3.0). Both are owned by the
  # container-mapped id so the in-container process can read them.
  exec { 'ferrogate-peer-genkey':
    command  => "openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 -out ${key_file}",
    path     => ['/usr/bin', '/bin'],
    provider => 'shell',
    creates  => $key_file,
    require  => File[$peer_dir],
  }

  exec { 'ferrogate-peer-gencert':
    command  => "openssl req -new -key ${key_file} -subj '/CN=${cert_cn}' -addext 'subjectAltName=${san}' -out ${csr_file} && openssl x509 -req -in ${csr_file} -CA ${ca_cert_file} -CAkey ${ca_key_file} -CAserial ${serial_file} -CAcreateserial -days ${ca_days} -copy_extensions copyall -out ${cert_file}", # lint:ignore:140chars
    path     => ['/usr/bin', '/bin'],
    provider => 'shell',
    creates  => $cert_file,
    require  => [Exec['ferrogate-peer-genkey'], File[$ca_cert_file], File[$ca_key_file]],
  }

  file { $key_file:
    ensure  => file,
    owner   => $_owner,
    group   => $_grp,
    mode    => '0640',
    require => Exec['ferrogate-peer-genkey'],
  }

  file { $cert_file:
    ensure  => file,
    owner   => $_owner,
    group   => $_grp,
    mode    => '0640',
    require => Exec['ferrogate-peer-gencert'],
  }
}
