# frozen_string_literal: true

# Detect the container runtime available on the host.
#
# Resolves to `'podman'` when the podman binary is on PATH (preferred),
# `'docker'` when only docker is present, or `nil` when neither is found.
# Consumed by the `ferrogate` class when its `runtime` parameter is `'auto'`.
Facter.add(:ferrogate_container_runtime) do
  confine kernel: 'Linux'
  setcode do
    if Facter::Util::Resolution.which('podman')
      'podman'
    elsif Facter::Util::Resolution.which('docker')
      'docker'
    end
  end
end
