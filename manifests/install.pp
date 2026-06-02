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
    # Rootless podman Quadlet user units only start at boot when the user has
    # systemd linger enabled. Subuid/subgid ranges are needed for the user
    # namespace; most distros seed them on user creation, but ensure they exist.
    if $manage_user {
      User[$user] -> Exec['ferrogate-enable-linger']
    }
    if $ferrogate::_manage_runtime {
      Package[$runtime] -> Exec['ferrogate-enable-linger']
    }

    exec { 'ferrogate-enable-linger':
      command => "loginctl enable-linger ${user}",
      path    => ['/usr/bin', '/bin'],
      unless  => "test \"$(loginctl show-user ${user} --property=Linger --value 2>/dev/null)\" = yes",
    }

    # Per-user XDG runtime dir for the rootless systemctl/podman calls below.
    $_xdg = "/run/user/${uid}"
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
        require     => Exec['ferrogate-enable-linger'],
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
