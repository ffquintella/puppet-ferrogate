# @summary Configure SELinux so containers can use the FerroGate directories.
#
# Private class — managed via the main `ferrogate` class. No-op when SELinux is
# disabled or when `$ferrogate::_manage_selinux` is false.
#
# Two things are needed for the bind-mounted host directories to work under an
# enforcing policy:
#
#   1. The directory *content* must carry the `container_file_t` type. The
#      Quadlet/`docker run` mounts already request this via the `:Z`/`:z`
#      relabel flag (see the `selinux_relabel` parameter), which relabels on
#      start. This class additionally pins a persistent `semanage fcontext`
#      rule so the labels survive a full filesystem `restorecon`.
#   2. Rootless podman managed by the per-user systemd instance needs the
#      `container_manage_cgroup` boolean enabled.
#
# @api private
class ferrogate::selinux {
  assert_private()

  $enabled = $facts['os']['selinux']['enabled']

  if $ferrogate::_manage_selinux and $enabled {
    $data_dir = $ferrogate::data_dir
    $logs_dir = $ferrogate::logs_dir

    # Allow rootless podman's systemd integration to manage container cgroups.
    if $ferrogate::_runtime == 'podman' {
      exec { 'ferrogate-selinux-container_manage_cgroup':
        command => 'setsebool -P container_manage_cgroup on',
        path    => ['/usr/sbin', '/sbin', '/usr/bin', '/bin'],
        unless  => 'test "$(getsebool container_manage_cgroup)" = "container_manage_cgroup --> on"',
      }
    }

    # Persist the container_file_t labelling for the writable host volumes so a
    # relabel does not strip the type that `:Z`/`:z` applies at mount time.
    exec { "ferrogate-fcontext-${data_dir}":
      command => "semanage fcontext -a -t container_file_t '${data_dir}(/.*)?' && restorecon -R '${data_dir}'",
      path    => ['/usr/sbin', '/sbin', '/usr/bin', '/bin'],
      unless  => "semanage fcontext -l | grep -qE '^${data_dir}\\(/\\.\\*\\)\\?\\s.*container_file_t'",
    }

    exec { "ferrogate-fcontext-${logs_dir}":
      command => "semanage fcontext -a -t container_file_t '${logs_dir}(/.*)?' && restorecon -R '${logs_dir}'",
      path    => ['/usr/sbin', '/sbin', '/usr/bin', '/bin'],
      unless  => "semanage fcontext -l | grep -qE '^${logs_dir}\\(/\\.\\*\\)\\?\\s.*container_file_t'",
    }
  }
}
