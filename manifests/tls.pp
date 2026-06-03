# @summary Provision the CMIS hybrid-PQC TLS certificate, key and SPKI pin.
#
# Private class — managed via the main `ferrogate` class, and only declared when
# CMIS is enabled and `cmis_tls_enable` is true. It lays out a `tls/`
# sub-directory under the config root holding the certificate (`cmis.crt`) and
# private key (`cmis.key`) that the CMIS listener reads through
# `CMIS_TLS_CERT` / `CMIS_TLS_KEY`. The directory is bind-mounted into the
# container by `ferrogate::service`.
#
# The certificate is either:
#   * **supplied** — when `cmis_tls_cert`/`cmis_tls_key` are set, written
#     verbatim; or
#   * **generated** — a self-signed P-384 certificate produced with OpenSSL when
#     no cert is supplied and `cmis_tls_manage_cert` is true (idempotent: only
#     created if the cert file is absent).
#
# In both cases the SHA-384 SPKI pin — the value MIA clients pin to authenticate
# CMIS (trust is by pin, not CA chain) — is computed and written to
# `<config_dir>/cmis.spki-pin.txt` so operators can read it off the node.
#
# @api private
class ferrogate::tls {
  assert_private()

  $user      = $ferrogate::_user
  $group     = $ferrogate::_group
  $uid       = $ferrogate::_uid
  $gid       = $ferrogate::_gid
  $runtime   = $ferrogate::_runtime

  $config_dir   = $ferrogate::config_dir
  $tls_dir      = $ferrogate::_tls_dir
  $cert_file    = $ferrogate::_tls_cert_file
  $key_file     = $ferrogate::_tls_key_file
  $pin_file     = $ferrogate::_tls_pin_file
  $cert         = $ferrogate::_cmis_tls_cert
  $key          = $ferrogate::_cmis_tls_key
  $manage_cert  = $ferrogate::_cmis_tls_manage_cert
  $cert_cn      = $ferrogate::_cmis_tls_cert_cn
  $cert_days    = $ferrogate::_cmis_tls_cert_days

  # The cert and key are read *from inside* the container by its non-root user.
  # Under rootless podman that internal id is remapped to a host subordinate id
  # (container id C -> subid_start + (C - 1)), so the files must be owned by that
  # mapped id rather than the login user. Under docker there is no remap. This
  # mirrors the volume-owner computation in ferrogate::config (recomputed
  # locally because the test evaluator does not resolve it across the class
  # boundary).
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

  # Both cert and key supplied ⇒ write them; otherwise generate.
  $_supplied = ($cert != undef and $key != undef)

  # --- tls/ directory (bind-mounted into the container) ---------------------
  file { $tls_dir:
    ensure  => directory,
    owner   => $_owner,
    group   => $_grp,
    mode    => '0750',
    require => File[$config_dir],
  }

  # --- Generate a self-signed certificate when none is supplied -------------
  if !$_supplied {
    # P-384 EC key + self-signed cert, non-interactive. `creates` makes it
    # idempotent; rotation is done by removing the cert (or supplying one).
    exec { 'ferrogate-tls-generate':
      command  => "openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-384 -keyout ${key_file} -out ${cert_file} -days ${cert_days} -nodes -subj '/CN=${cert_cn}'", # lint:ignore:140chars
      path     => ['/usr/bin', '/bin'],
      provider => 'shell',
      creates  => $cert_file,
      require  => File[$tls_dir],
    }
    $_material_anchor = Exec['ferrogate-tls-generate']
  } else {
    $_material_anchor = File[$tls_dir]
  }

  # --- Certificate and key files --------------------------------------------
  # When supplied, the File carries the PEM content. When generated, the File
  # only enforces ownership/mode over the OpenSSL-produced file (it requires the
  # generate exec, which has already created it). Owned by the container-mapped
  # id so the in-container process can read them.
  file { $cert_file:
    ensure  => file,
    owner   => $_owner,
    group   => $_grp,
    mode    => '0640',
    content => $_supplied ? { true => $cert, default => undef },
    require => $_material_anchor,
  }

  file { $key_file:
    ensure  => file,
    owner   => $_owner,
    group   => $_grp,
    mode    => '0640',
    content => $_supplied ? { true => $key, default => undef },
    require => $_material_anchor,
  }

  # --- SPKI pin (SHA-384 of the cert's SubjectPublicKeyInfo) ----------------
  # The lowercase-hex value MIA clients pin (RFC 7469 construction, SHA-384).
  # Recomputed whenever the certificate is newer than the pin file (covers both
  # first run and rotation). `provider => shell` so the pipeline runs under sh.
  exec { 'ferrogate-tls-spki-pin':
    command  => "openssl x509 -in ${cert_file} -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha384 | sed 's/^.*= *//' > ${pin_file}", # lint:ignore:140chars
    path     => ['/usr/bin', '/bin'],
    provider => 'shell',
    unless   => "test ${pin_file} -nt ${cert_file}",
    require  => File[$cert_file],
  }

  # Pin file is non-secret; keep it login-user-owned and group/operator-readable.
  file { $pin_file:
    ensure  => file,
    owner   => $user,
    group   => $group,
    mode    => '0644',
    require => Exec['ferrogate-tls-spki-pin'],
  }
}
