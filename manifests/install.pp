# @summary Install the container runtime, the FerroGate user, and pull the image.
#
# Private class — managed via the main `ferrogate` class. Creates the dedicated
# unprivileged user/group, installs podman or docker, enables systemd linger for
# the user (required so rootless podman Quadlet user units start at boot), and
# pulls the configured image.
#
# @api private
class ferrogate::install {
  assert_private()

  $runtime     = $ferrogate::_runtime
  $image       = $ferrogate::_image
  $user        = $ferrogate::_user
  $group       = $ferrogate::_group
  $uid         = $ferrogate::_uid
  $gid         = $ferrogate::_gid
  $manage_user = $ferrogate::_manage_user

  # --- Dedicated unprivileged user ------------------------------------------
  if $manage_user {
    group { $group:
      ensure => present,
      gid    => $gid,
      system => true,
    }

    user { $user:
      ensure     => present,
      uid        => $uid,
      gid        => $gid,
      home       => "/home/${user}",
      managehome => true,
      shell      => '/usr/sbin/nologin',
      system     => true,
      comment    => 'FerroGate service account',
      require    => Group[$group],
    }
  }

  # --- Container runtime package --------------------------------------------
  # Guard with !defined() so the runtime package coexists with any other module
  # that installs the same package on the node (e.g. bastionvault also installs
  # podman, via ensure_packages). Without the guard, two plain `package {}`
  # declarations collide with a duplicate-declaration error. Package[$runtime]
  # stays addressable for the ordering arrows below.
  if $ferrogate::_manage_runtime and !defined(Package[$runtime]) {
    package { $runtime:
      ensure => installed,
    }
  }

  if $runtime == 'podman' {
    # Rootless podman maps container UIDs/GIDs through the user's subordinate ID
    # ranges (/etc/subuid, /etc/subgid). `useradd` does NOT allocate these for
    # system users, so without an explicit range image layers that carry
    # non-root ownership (e.g. /etc/gshadow, gid 42) fail to unpack with
    # "potentially insufficient UIDs or GIDs available in user namespace".
    # Give the user its own contiguous block, derived from its uid by default so
    # it is deterministic and does not overlap other users' blocks.
    # Default the start to a deterministic per-uid block when unset. Computed
    # here from the local $uid rather than in init.pp because the test
    # evaluator does not resolve a pick()/function default across the class
    # boundary, whereas a plain qualified body var (e.g. $ferrogate::_uid) does.
    $_subid_count = $ferrogate::_subid_count
    $_subid_start = $ferrogate::_subid_start ? {
      undef   => $uid * 65536,
      default => $ferrogate::_subid_start,
    }

    if $manage_user {
      User[$user] -> Exec['ferrogate-enable-linger']

      case $ferrogate::_subid_management {
        'usermod': {
          # Standalone: append directly with usermod. Only safe when nothing
          # else owns /etc/subuid|subgid. If the puppet/podman module manages
          # them (concat), it will purge these entries every run — switch to
          # `subid_management => 'podman'` on such nodes.
          $_subid_end = $_subid_start + $_subid_count - 1

          exec { 'ferrogate-add-subids':
            command => "usermod --add-subuids ${_subid_start}-${_subid_end} --add-subgids ${_subid_start}-${_subid_end} ${user}",
            path    => ['/usr/sbin', '/sbin', '/usr/bin', '/bin'],
            unless  => "grep -q '^${user}:' /etc/subuid && grep -q '^${user}:' /etc/subgid",
            require => User[$user],
            before  => Exec['ferrogate-enable-linger'],
          }
        }
        'podman': {
          # Register the ranges through the puppet/podman module so they become
          # concat fragments of its managed /etc/subuid|subgid instead of being
          # purged by it. Requires the puppet/podman module and its `podman`
          # class to be declared on the node (e.g. via bastionvault).
          podman::subuid { $user:
            subuid => $_subid_start,
            count  => $_subid_count,
          }
          podman::subgid { $user:
            subgid => $_subid_start,
            count  => $_subid_count,
          }
          Podman::Subuid[$user] -> Exec['ferrogate-enable-linger']
          Podman::Subgid[$user] -> Exec['ferrogate-enable-linger']
        }
        default: {
          # 'none': subids managed elsewhere; do nothing here.
        }
      }
    }
    if $ferrogate::_manage_runtime {
      Package[$runtime] -> Exec['ferrogate-enable-linger']
    }

    # Rootless podman Quadlet user units only start at boot when the user has
    # systemd linger enabled.
    exec { 'ferrogate-enable-linger':
      command => "loginctl enable-linger ${user}",
      path    => ['/usr/bin', '/bin'],
      unless  => "test \"$(loginctl show-user ${user} --property=Linger --value 2>/dev/null)\" = yes",
    }

    # Per-user XDG runtime dir for the rootless systemctl/podman calls below.
    $_xdg = "/run/user/${uid}"

    # Re-read the subordinate ID ranges into the user's rootless container
    # storage. Required when the ranges are (re)added after storage already
    # exists (the failed first pull initialises it); a no-op once the image is
    # present, so it stops running after the first successful pull.
    exec { 'ferrogate-podman-migrate':
      command     => 'podman system migrate',
      path        => ['/usr/bin', '/bin'],
      user        => $user,
      cwd         => "/home/${user}",
      environment => ["XDG_RUNTIME_DIR=${_xdg}", "HOME=/home/${user}"],
      unless      => "podman image exists ${image}",
      require     => Exec['ferrogate-enable-linger'],
    }
  }

  # --- Pull the image -------------------------------------------------------
  if $ferrogate::_pull_image {
    if $runtime == 'podman' {
      # Pull rootless, into the dedicated user's storage.
      exec { 'ferrogate-pull-image':
        command     => "podman pull ${image}",
        path        => ['/usr/bin', '/bin'],
        user        => $user,
        cwd         => "/home/${user}",
        environment => ["XDG_RUNTIME_DIR=${_xdg}", "HOME=/home/${user}"],
        unless      => "podman image exists ${image}",
        timeout     => 600,
        require     => Exec['ferrogate-podman-migrate'],
      }
    } else {
      exec { 'ferrogate-pull-image':
        command => "docker pull ${image}",
        path    => ['/usr/bin', '/bin'],
        unless  => "docker image inspect ${image}",
        timeout => 600,
      }
      if $ferrogate::_manage_runtime {
        Package[$runtime] -> Exec['ferrogate-pull-image']
      }
    }
  }
}
