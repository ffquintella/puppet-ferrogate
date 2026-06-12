# @summary Manage a single FerroGate container instance under systemd.
#
# For **podman** this writes a rootless [Quadlet](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)
# `.container` unit into the dedicated user's
# `~/.config/containers/systemd/` and starts it through the user's systemd
# instance (`systemctl --user`). For **docker** it writes a system unit under
# `/etc/systemd/system/` whose `ExecStart` runs `docker run`, managed with the
# native `service` resource.
#
# This define is consumed by `ferrogate::service`; declare the `ferrogate`
# class rather than using it directly.
#
# @param command
#   FerroGate server to run inside the container (`cmis` or `mia`).
# @param env_file
#   Absolute path to the rendered environment file passed to the container.
# @param volumes
#   `host:container` bind-mount specs. The SELinux relabel suffix from
#   `$ferrogate::_selinux_relabel` is appended automatically.
# @param ports
#   `host:container` port publications (podman `PublishPort` / docker `-p`).
# @param devices
#   Host device paths passed into the container.
# @param networks
#   Container network modes (podman `Network=` / docker `--network`). Empty (the
#   default) leaves the runtime default — rootless `pasta` with published ports.
#   A multi-node CMIS cluster sets `['host']`: the node must bind a routable host
#   interface so peers can reach it and the leader can dial its own advertised
#   FQDN (rootless pasta cannot hairpin a published port back into its own
#   container). With host networking the ports bind directly on the host, so
#   `ports` is left empty.
# @param ensure
#   Whether the instance should be `running`/`present` or `stopped`/`absent`.
#
# @api private
define ferrogate::instance (
  String[1]                                $command,
  Stdlib::Absolutepath                     $env_file,
  Array[String[1]]                         $volumes  = [],
  Array[String[1]]                         $ports    = [],
  Array[Stdlib::Absolutepath]              $devices  = [],
  Array[String[1]]                         $networks = [],
  Enum['running', 'stopped']               $ensure   = 'running',
) {
  assert_private()

  $runtime  = $ferrogate::_runtime
  $image    = $ferrogate::_image
  $user     = $ferrogate::_user
  $uid      = $ferrogate::_uid
  $gid      = $ferrogate::_gid
  $relabel  = $ferrogate::_selinux_relabel
  $svc      = "ferrogate-${command}"

  # Append the SELinux relabel flag to each volume unless disabled.
  if $relabel == 'none' {
    $_volumes = $volumes
  } else {
    $_volumes = $volumes.map |$v| { "${v}:${relabel}" }
  }

  $_params = {
    'svc'      => $svc,
    'command'  => $command,
    'image'    => $image,
    'env_file' => $env_file,
    'volumes'  => $_volumes,
    'ports'    => $ports,
    'devices'  => $devices,
    'uid'      => $uid,
    'gid'      => $gid,
    'networks' => $networks,
  }

  if $runtime == 'podman' {
    $_config_dir = "/home/${user}/.config"
    $_cont_dir   = "${_config_dir}/containers"
    $_unit_dir   = "${_cont_dir}/systemd"
    $_xdg        = "/run/user/${uid}"
    $_sysd       = "XDG_RUNTIME_DIR=${_xdg}"

    # Puppet does not create parent directories implicitly, and `recurse` only
    # manages children downward, never the path above. Declare the full chain
    # (~/.config -> containers -> systemd) so the Quadlet unit dir can be
    # created on a fresh user home. Shared across instances via ensure_resource.
    ensure_resource('file', $_config_dir, {
        'ensure' => 'directory',
        'owner'  => $user,
        'group'  => $ferrogate::_group,
        'mode'   => '0700',
    })

    ensure_resource('file', $_cont_dir, {
        'ensure'  => 'directory',
        'owner'   => $user,
        'group'   => $ferrogate::_group,
        'mode'    => '0700',
        'require' => File[$_config_dir],
    })

    ensure_resource('file', $_unit_dir, {
        'ensure'  => 'directory',
        'owner'   => $user,
        'group'   => $ferrogate::_group,
        'mode'    => '0700',
        'require' => File[$_cont_dir],
    })

    file { "${_unit_dir}/${svc}.container":
      ensure  => file,
      owner   => $user,
      group   => $ferrogate::_group,
      mode    => '0640',
      content => epp('ferrogate/quadlet.container.epp', $_params),
      require => File[$_unit_dir],
      notify  => Exec["ferrogate-user-daemon-reload-${command}"],
    }

    # Reload the user systemd manager so the Quadlet generator picks up changes.
    exec { "ferrogate-user-daemon-reload-${command}":
      command     => 'systemctl --user daemon-reload',
      path        => ['/usr/bin', '/bin'],
      user        => $user,
      cwd         => "/home/${user}",
      environment => [$_sysd, "HOME=/home/${user}"],
      refreshonly => true,
    }

    if $ensure == 'running' {
      # Quadlet generates the `.service` unit from the `.container` file, so it
      # is a transient/generated unit that cannot be `systemctl enable`d
      # ("Unit ... is transient or generated"). Boot autostart is instead wired
      # by the `[Install] WantedBy=default.target` section in the unit, which
      # the generator turns into a wants-symlink on each daemon-reload (and
      # linger, enabled in install.pp, lets the user manager start it at boot).
      # So the only runtime action here is to start it.
      exec { "ferrogate-user-start-${command}":
        command     => "systemctl --user start ${svc}.service",
        path        => ['/usr/bin', '/bin'],
        user        => $user,
        cwd         => "/home/${user}",
        environment => [$_sysd, "HOME=/home/${user}"],
        unless      => "systemctl --user is-active --quiet ${svc}.service",
        require     => Exec["ferrogate-user-daemon-reload-${command}"],
        subscribe   => File["${_unit_dir}/${svc}.container"],
      }
    } else {
      exec { "ferrogate-user-stop-${command}":
        command     => "systemctl --user stop ${svc}.service",
        path        => ['/usr/bin', '/bin'],
        user        => $user,
        cwd         => "/home/${user}",
        environment => [$_sysd, "HOME=/home/${user}"],
        onlyif      => "systemctl --user is-active --quiet ${svc}.service",
        require     => Exec["ferrogate-user-daemon-reload-${command}"],
      }
    }
  } else {
    # --- docker: plain system unit -----------------------------------------
    file { "/etc/systemd/system/${svc}.service":
      ensure  => file,
      owner   => 'root',
      group   => 'root',
      mode    => '0644',
      content => epp('ferrogate/docker.service.epp', $_params),
      notify  => Exec['ferrogate-systemd-daemon-reload'],
    }

    ensure_resource('exec', 'ferrogate-systemd-daemon-reload', {
        'command'     => 'systemctl daemon-reload',
        'path'        => ['/usr/bin', '/bin'],
        'refreshonly' => true,
    })

    service { $svc:
      ensure    => $ensure ? { 'running' => 'running', default => 'stopped' },
      enable    => $ensure ? { 'running' => true, default => false },
      provider  => 'systemd',
      require   => File["/etc/systemd/system/${svc}.service"],
      subscribe => [
        File["/etc/systemd/system/${svc}.service"],
        Exec['ferrogate-systemd-daemon-reload'],
      ],
    }
  }
}
