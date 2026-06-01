require 'spec_helper'

# Shared facts: a Linux host with podman detected and SELinux enabled.
BASE_FACTS = {
  ferrogate_container_runtime: 'podman',
  os: {
    family:  'RedHat',
    name:    'Rocky',
    release: { major: '9', full: '9.3' },
    selinux: { 'enabled' => true },
  },
}.freeze

describe 'ferrogate' do
  context 'with podman defaults (both services)' do
    let(:facts) { BASE_FACTS }

    it { is_expected.to compile }

    it 'creates the dedicated service user and group' do
      is_expected.to contain_user('ferrogate').with(
        uid:    10001,
        gid:    10001,
        system: true,
        shell:  '/usr/sbin/nologin',
      )
      is_expected.to contain_group('ferrogate').with(gid: 10001, system: true)
    end

    it 'installs the podman package' do
      is_expected.to contain_package('podman').with(ensure: 'installed')
    end

    it 'enables systemd linger for rootless podman' do
      is_expected.to contain_exec('ferrogate-enable-linger')
    end

    it 'pulls the image rootless as the service user' do
      is_expected.to contain_exec('ferrogate-pull-image').with(
        command: 'podman pull ferrogate:latest',
        user:    'ferrogate',
      )
    end

    it 'declares the baseapp directory layout' do
      is_expected.to contain_class('baseapp')
    end

    ['/srv/application-config/ferrogate',
     '/srv/application-data/ferrogate',
     '/srv/application-data/ferrogate/audit',
     '/srv/application-logs/ferrogate'].each do |dir|
      it "manages directory #{dir}" do
        is_expected.to contain_file(dir).with(
          ensure: 'directory',
          owner:  'ferrogate',
          group:  'ferrogate',
          mode:   '0750',
        )
      end
    end

    it 'renders the cmis and mia env files' do
      is_expected.to contain_file('/srv/application-config/ferrogate/cmis.env')
      is_expected.to contain_file('/srv/application-config/ferrogate/mia.env')
    end

    it 'declares a cmis instance that publishes the gRPC port and mounts the volumes' do
      is_expected.to contain_ferrogate__instance('cmis').with(
        command:  'cmis',
        env_file: '/srv/application-config/ferrogate/cmis.env',
        ports:    ['8443:8443'],
        volumes:  [
          '/srv/application-logs/ferrogate:/opt/ferrogate/logs',
          '/srv/application-data/ferrogate/audit:/var/lib/ferrogate/audit',
        ],
      )
    end

    it 'declares a mia instance with the TPM device' do
      is_expected.to contain_ferrogate__instance('mia').with(
        command: 'mia',
        devices: ['/dev/tpmrm0'],
      )
    end

    it 'configures SELinux booleans and file contexts' do
      is_expected.to contain_exec('ferrogate-selinux-container_manage_cgroup')
      is_expected.to contain_exec('ferrogate-fcontext-/srv/application-data/ferrogate')
    end
  end

  context 'with an environment variant' do
    let(:facts) { BASE_FACTS }
    let(:params) { { app_environment: 'staging' } }

    it { is_expected.to compile }

    it 'nests directories under the environment variant' do
      is_expected.to contain_file('/srv/application-config/ferrogate/staging').with(ensure: 'directory')
      is_expected.to contain_file('/srv/application-data/ferrogate/staging/audit').with(ensure: 'directory')
    end
  end

  context 'with docker runtime' do
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
    let(:params) { { runtime: 'docker' } }

    it { is_expected.to compile }

    it 'installs docker' do
      is_expected.to contain_package('docker').with(ensure: 'installed')
    end

    it 'pulls the image with docker' do
      is_expected.to contain_exec('ferrogate-pull-image').with(command: 'docker pull ferrogate:latest')
    end

    it 'declares the cmis instance (docker unit rendered by the define)' do
      is_expected.to contain_ferrogate__instance('cmis').with(command: 'cmis')
    end
  end

  context 'with a configurable registry and tag' do
    let(:facts) { BASE_FACTS }
    let(:params) do
      {
        registry:  'registry.example.com/fgv',
        image_tag: '1.4.0',
      }
    end

    it { is_expected.to compile }

    it 'composes the fully-qualified image reference' do
      is_expected.to contain_exec('ferrogate-pull-image').with(
        command: 'podman pull registry.example.com/fgv/ferrogate:1.4.0',
      )
    end
  end

  context 'with only cmis enabled' do
    let(:facts) { BASE_FACTS }
    let(:params) { { mia_enable: false } }

    it { is_expected.to compile }

    it 'still renders the cmis env file' do
      is_expected.to contain_file('/srv/application-config/ferrogate/cmis.env')
    end
  end
end
