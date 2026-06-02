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
    # Give the user its own contiguous 65536-id block, derived from its uid so
    # it is deterministic and does not overlap other users' blocks.
    if $manage_user {
      User[$user] -> Exec['ferrogate-enable-linger']

      $_subid_start = $uid * 65536
      $_subid_end   = $_subid_start + 65535

      exec { 'ferrogate-add-subids':
        command => "usermod --add-subuids ${_subid_start}-${_subid_end} --add-subgids ${_subid_start}-${_subid_end} ${user}",
        path    => ['/usr/sbin', '/sbin', '/usr/bin', '/bin'],
        unless  => "grep -q '^${user}:' /etc/subuid && grep -q '^${user}:' /etc/subgid",
        require => User[$user],
        before  => Exec['ferrogate-enable-linger'],
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
