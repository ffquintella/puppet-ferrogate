require 'spec_helper'

# The MIA host-agent client class is deliberately standalone: it has no
# dependency on the `ferrogate` server class, `baseapp`, or a container runtime,
# so a bare RedHat-family fact set is enough to compile it.
MIA_FACTS = {
  os: {
    family:  'RedHat',
    name:    'Rocky',
    release: { major: '9', full: '9.3' },
  },
}.freeze

describe 'ferrogate::mia' do
  context 'with defaults' do
    let(:facts) { MIA_FACTS }

    it { is_expected.to compile }

    it 'installs the MIA host package' do
      is_expected.to contain_package('ferrogate-mia').with(ensure: 'installed')
    end

    it 'manages the config directory' do
      is_expected.to contain_file('/etc/ferrogate').with(
        ensure: 'directory',
        owner:  'root',
        group:  'root',
        mode:   '0755',
      )
    end

    it 'renders the EnvironmentFile read by the mia unit' do
      is_expected.to contain_file('/etc/ferrogate/mia.env').with(
        ensure: 'file',
        owner:  'root',
        group:  'root',
        mode:   '0640',
      )
    end

    it 'enables and runs the mia service via systemd' do
      is_expected.to contain_service('mia').with(
        ensure:   'running',
        enable:   true,
        provider: 'systemd',
      )
    end
  end

  context 'pointed at a CMIS server with an allowlist' do
    let(:facts) { MIA_FACTS }
    let(:params) do
      {
        cmis_endpoint:  'https://cmis.example.com:8443',
        cmis_spki_pin:  '5f2ec4',
        allowlist_path: '/etc/ferrogate/allowlist.cbor',
        allowlist_key:  '/etc/ferrogate/allowlist.pub',
      }
    end

    it { is_expected.to compile }

    it 'writes the CMIS endpoint, pin and allowlist into the env file' do
      is_expected.to contain_file('/etc/ferrogate/mia.env')
        .with_content(%r{FERROGATE_CMIS_ENDPOINT=https://cmis\.example\.com:8443})
        .with_content(%r{FERROGATE_CMIS_SPKI_PIN=5f2ec4})
        .with_content(%r{FERROGATE_ALLOWLIST=/etc/ferrogate/allowlist\.cbor})
        .with_content(%r{FERROGATE_ALLOWLIST_KEY=/etc/ferrogate/allowlist\.pub})
    end
  end

  context 'with an allowlist path but no key' do
    let(:facts) { MIA_FACTS }
    let(:params) { { allowlist_path: '/etc/ferrogate/allowlist.cbor' } }

    it 'fails compilation with a clear error' do
      is_expected.to compile.and_raise_error(%r{allowlist_key is required})
    end
  end

  context 'with the service unmanaged' do
    let(:facts) { MIA_FACTS }
    let(:params) { { manage_service: false } }

    it { is_expected.to compile }

    it 'does not declare the service' do
      is_expected.not_to contain_service('mia')
    end
  end

  context 'with the package unmanaged' do
    let(:facts) { MIA_FACTS }
    let(:params) { { manage_package: false } }

    it { is_expected.to compile }

    it 'does not declare the package' do
      is_expected.not_to contain_package('ferrogate-mia')
    end
  end

  context 'with repo management off (default)' do
    let(:facts) { MIA_FACTS }

    it 'declares no custom repository' do
      is_expected.not_to contain_yumrepo('ferrogate-mia')
      is_expected.not_to contain_file('/etc/apt/sources.list.d/ferrogate-mia.list')
    end
  end

  context 'with a custom repo on the RedHat family' do
    let(:facts) { MIA_FACTS }
    let(:params) do
      {
        manage_repo:  true,
        repo_baseurl: 'https://repo.example.com/ferrogate/el9/x86_64',
        repo_gpgkey:  'https://repo.example.com/ferrogate/RPM-GPG-KEY',
      }
    end

    it { is_expected.to compile }

    it 'declares the yumrepo and orders it before the package' do
      is_expected.to contain_yumrepo('ferrogate-mia').with(
        ensure:   'present',
        baseurl:  'https://repo.example.com/ferrogate/el9/x86_64',
        enabled:  1,
        gpgcheck: 1,
        gpgkey:   'https://repo.example.com/ferrogate/RPM-GPG-KEY',
      )
    end
  end

  context 'with manage_repo but no baseurl' do
    let(:facts) { MIA_FACTS }
    let(:params) { { manage_repo: true } }

    it 'fails compilation with a clear error' do
      is_expected.to compile.and_raise_error(%r{repo_baseurl is required})
    end
  end

  context 'with a custom repo on the Debian family' do
    let(:facts) do
      {
        os: {
          family:  'Debian',
          name:    'Ubuntu',
          release: { major: '24.04', full: '24.04' },
          distro:  { codename: 'noble' },
        },
      }
    end
    let(:params) do
      {
        manage_repo:  true,
        repo_baseurl: 'https://repo.example.com/ferrogate/apt',
        repo_gpgkey:  '/etc/apt/keyrings/ferrogate.gpg',
      }
    end

    it { is_expected.to compile }

    it 'writes a signed apt source list' do
      is_expected.to contain_file('/etc/apt/sources.list.d/ferrogate-mia.list')
        .with_content(%r{deb \[signed-by=/etc/apt/keyrings/ferrogate\.gpg\] https://repo\.example\.com/ferrogate/apt noble main})
    end
  end
end
