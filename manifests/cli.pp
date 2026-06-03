# @summary Install the host-side `ferrogate` operator CLI wrapper.
#
# Private class — managed via the main `ferrogate` class. The `ferrogate`
# operator CLI binary ships *inside* the server image (alongside `cmis`) but
# nothing on the host exposes it. This class drops a thin
# `/usr/local/bin/ferrogate` wrapper that re-execs into the running
# `ferrogate-cmis` container and runs the in-container CLI:
#
#   * **podman** — `sudo` to the rootless service user, then `podman exec` so we
#     reach that user's container storage and the container's network
#     namespace.
#   * **docker** — `sudo` to root, then `docker exec`.
#
# The CLI is a gRPC client whose default endpoint is `http://127.0.0.1:<port>`.
# Because the wrapper execs *inside* the cmis container, that loopback address
# reaches CMIS over the container's own netns — no host port publication or TLS
# trust plumbing is required. The wrapper injects `--endpoint` pinned to the
# configured container port so a non-default `cmis_container_port` still works;
# an operator-supplied `--endpoint` on the command line overrides it.
#
# Access is granted to members of the FerroGate group via a dedicated
# `/etc/sudoers.d/ferrogate-cli` drop-in. This class is only declared when CMIS
# is enabled (the CLI has no server to talk to otherwise).
#
# The runtime selects which (conditional-free) template renders — the branch is
# resolved here in Puppet rather than inside the EPP.
#
# @api private
class ferrogate::cli {
  assert_private()

  $user           = $ferrogate::_user
  $group          = $ferrogate::_group
  $uid            = $ferrogate::_uid
  $runtime        = $ferrogate::_runtime
  $container_port = $ferrogate::_cmis_container_port

  # CMIS speaks TLS on its listen port when tls is enabled, so the loopback
  # endpoint scheme must match. (Requires a CLI build with F01 TLS support — see
  # the cmis_tls_enable caveat in the class docs.)
  $scheme = $ferrogate::_cmis_tls_enable ? {
    true    => 'https',
    default => 'http',
  }

  # The cmis instance is named `ferrogate-cmis` (ferrogate::instance derives the
  # container/unit name as "ferrogate-${command}").
  $container = 'ferrogate-cmis'

  if $runtime == 'podman' {
    $wrapper_content = epp('ferrogate/ferrogate-cli-podman.sh.epp', {
        'user'           => $user,
        'uid'            => $uid,
        'container'      => $container,
        'container_port' => $container_port,
        'scheme'         => $scheme,
    })
    $sudoers_content = epp('ferrogate/ferrogate-cli-sudoers-podman.epp', {
        'user'      => $user,
        'group'     => $group,
        'uid'       => $uid,
        'container' => $container,
    })
  } else {
    $wrapper_content = epp('ferrogate/ferrogate-cli-docker.sh.epp', {
        'container'      => $container,
        'container_port' => $container_port,
        'scheme'         => $scheme,
    })
    $sudoers_content = epp('ferrogate/ferrogate-cli-sudoers-docker.epp', {
        'group'     => $group,
        'container' => $container,
    })
  }

  file { '/usr/local/bin/ferrogate':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0755',
    content => $wrapper_content,
  }

  file { '/etc/sudoers.d/ferrogate-cli':
    ensure       => file,
    owner        => 'root',
    group        => 'root',
    mode         => '0440',
    content      => $sudoers_content,
    validate_cmd => '/usr/sbin/visudo -cf %',
  }
}
