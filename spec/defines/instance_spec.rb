require 'spec_helper'

# NOTE: regent's embedded evaluator records a defined-type *declaration* and its
# parameters, but does not expand the define body into its inner resources.
# These specs therefore assert compilation under both runtimes; the rendered
# unit files are exercised indirectly through the class spec's
# `contain_ferrogate__instance` parameter assertions.
describe 'ferrogate::instance' do
  # `include ferrogate` already declares the real `cmis` instance, so probe
  # with a different title/command to avoid a duplicate declaration.
  let(:title) { 'probe' }

  context 'with podman (rootless Quadlet unit)' do
    let(:facts) do
      {
        ferrogate_container_runtime: 'podman',
        os: {
          family:  'RedHat',
          name:    'Rocky',
          release: { major: '9', full: '9.3' },
          selinux: { 'enabled' => true },
        },
      }
    end
    let(:pre_condition) { 'include ferrogate' }
    let(:params) do
      {
        command:  'probe',
        env_file: '/srv/application-config/ferrogate/cmis.env',
        volumes:  ['/srv/application-logs/ferrogate:/opt/ferrogate/logs'],
        ports:    ['8443:8443'],
        devices:  [],
      }
    end

    it { is_expected.to compile }
  end

  context 'with docker (system unit)' do
    let(:facts) do
      {
        ferrogate_container_runtime: 'docker',
        os: {
          family:  'RedHat',
          name:    'Rocky',
          release: { major: '9', full: '9.3' },
          selinux: { 'enabled' => true },
        },
      }
    end
    let(:pre_condition) { "class { 'ferrogate': runtime => 'docker' }" }
    let(:params) do
      {
        command:  'probe',
        env_file: '/srv/application-config/ferrogate/cmis.env',
        volumes:  ['/srv/application-logs/ferrogate:/opt/ferrogate/logs'],
        ports:    ['8443:8443'],
        devices:  [],
      }
    end

    it { is_expected.to compile }
  end
end
