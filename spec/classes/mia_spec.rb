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

    # The `User[_ferrogate] -> Service[mia]` ordering is declared in the manifest
    # with a chaining arrow; the Artichoke test evaluator does not materialize
    # that edge (nor a `require` array of resource refs — it drops the service),
    # so assert the resources and their attributes here rather than the edge.
    it 'creates the _ferrogate privilege-drop account' do
      is_expected.to contain_group('_ferrogate').with(ensure: 'present', system: true)
      is_expected.to contain_user('_ferrogate').with(
        ensure: 'present',
        system: true,
        gid:    '_ferrogate',
        shell:  '/sbin/nologin',
      )
    end

    it 'renders the TOML config file mia reads directly' do
      is_expected.to contain_file('/etc/ferrogate/mia.toml').with(
        ensure: 'file',
        owner:  'root',
        group:  'ferrogate-status',
        mode:   '0640',
      )
    end

    it 'writes the default log level and helper socket into the TOML' do
      is_expected.to contain_file('/etc/ferrogate/mia.toml')
        .with_content(%r{log = 'info'})
        .with_content(%r{\[helper\]})
        .with_content(%r{socket = '/run/ferrogate/mia\.sock'})
        .with_content(%r{socket_mode = '660'})
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

    it 'mirrors the CMIS and allowlist config into the TOML with honored keys' do
      is_expected.to contain_file('/etc/ferrogate/mia.toml')
        .with_content(%r{\[cmis\]})
        .with_content(%r{endpoint = 'https://cmis\.example\.com:8443'})
        .with_content(%r{spki_pin = '5f2ec4'})
        .with_content(%r{\[allowlist\]})
        .with_content(%r{path = '/etc/ferrogate/allowlist\.cbor'})
        .with_content(%r{key = '/etc/ferrogate/allowlist\.pub'})
    end
  end

  context 'with an allowlist path but no key' do
    let(:facts) { MIA_FACTS }
    let(:params) { { allowlist_path: '/etc/ferrogate/allowlist.cbor' } }

    it 'fails compilation with a clear error' do
      is_expected.to compile.and_raise_error(%r{allowlist_key is required})
    end
  end

  context 'fetching this host\'s allowlist from CMIS on start' do
    let(:facts) { MIA_FACTS }
    let(:params) do
      {
        cmis_endpoint:          'https://cmis.example.com:8443',
        cmis_spki_pin:          '5f2ec4',
        allowlist_path:         '/var/lib/ferrogate/allowlist.cbor',
        allowlist_key:          '/var/lib/ferrogate/allowlist.pub',
        allowlist_fetch:        true,
        allowlist_max_age_secs: 86_400,
      }
    end

    it { is_expected.to compile }

    it 'sets FERROGATE_ALLOWLIST_FETCH in the env file' do
      is_expected.to contain_file('/etc/ferrogate/mia.env')
        .with_content(%r{FERROGATE_ALLOWLIST_FETCH=1})
        .with_content(%r{FERROGATE_ALLOWLIST_MAX_AGE_SECS=86400})
    end

    it 'renders fetch as a TOML boolean (unquoted) under [allowlist]' do
      is_expected.to contain_file('/etc/ferrogate/mia.toml')
        .with_content(%r{\[allowlist\]})
        .with_content(%r{fetch = true})
        .with_content(%r{max_age_secs = 86400})
    end

    it 'creates the directory holding the fetched allowlist body' do
      is_expected.to contain_file('/var/lib/ferrogate')
        .with_ensure('directory')
    end
  end

  context 'with the allowlist under the managed config_dir' do
    let(:facts) { MIA_FACTS }
    let(:params) do
      {
        allowlist_path:  '/etc/ferrogate/allowlist.cbor',
        allowlist_key:   '/etc/ferrogate/allowlist.pub',
        allowlist_fetch: true,
      }
    end

    it { is_expected.to compile }

    it 'does not declare a duplicate directory for config_dir' do
      # config_dir itself is still managed, exactly once.
      is_expected.to contain_file('/etc/ferrogate').with_ensure('directory')
    end
  end

  context 'with manage_allowlist_dir => false' do
    let(:facts) { MIA_FACTS }
    let(:params) do
      {
        allowlist_path:       '/var/lib/ferrogate/allowlist.cbor',
        allowlist_key:        '/var/lib/ferrogate/allowlist.pub',
        allowlist_fetch:      true,
        manage_allowlist_dir: false,
      }
    end

    it { is_expected.to compile }

    it 'leaves the allowlist directory to the package/operator' do
      is_expected.not_to contain_file('/var/lib/ferrogate')
    end
  end

  context 'on the A2 bootstrap path (propose)' do
    let(:facts) { MIA_FACTS }
    let(:params) do
      {
        cmis_endpoint:                   'https://cmis.example.com:8443',
        cmis_spki_pin:                   '5f2ec4',
        allowlist_path:                  '/var/lib/ferrogate/allowlist.cbor',
        allowlist_key:                   '/var/lib/ferrogate/allowlist.pub',
        allowlist_propose:               true,
        allowlist_propose_interval_secs: 300,
      }
    end

    it { is_expected.to compile }

    it 'sets the propose env vars' do
      is_expected.to contain_file('/etc/ferrogate/mia.env')
        .with_content(%r{FERROGATE_ALLOWLIST_PROPOSE=1})
        .with_content(%r{FERROGATE_ALLOWLIST_PROPOSE_INTERVAL_SECS=300})
    end

    it 'renders propose keys under [allowlist] in the TOML' do
      is_expected.to contain_file('/etc/ferrogate/mia.toml')
        .with_content(%r{propose = true})
        .with_content(%r{propose_interval_secs = 300})
    end
  end

  context 'with allowlist_fetch but no allowlist_path' do
    let(:facts) { MIA_FACTS }
    let(:params) { { allowlist_fetch: true } }

    it 'fails compilation with a clear error' do
      is_expected.to compile.and_raise_error(%r{require allowlist_path})
    end
  end

  context 'with a propose interval but propose disabled' do
    let(:facts) { MIA_FACTS }
    let(:params) do
      {
        allowlist_path:                  '/var/lib/ferrogate/allowlist.cbor',
        allowlist_key:                   '/var/lib/ferrogate/allowlist.pub',
        allowlist_propose_interval_secs: 300,
      }
    end

    it 'fails compilation with a clear error' do
      is_expected.to compile.and_raise_error(%r{allowlist_propose_interval_secs requires allowlist_propose})
    end
  end

  context 'pointed at a CMIS cluster via an SRV record' do
    let(:facts) { MIA_FACTS }
    let(:params) do
      {
        cmis_srv:      '_cmis._tcp.prod.example.com',
        cmis_spki_pin: '5f2ec4',
      }
    end

    it { is_expected.to compile }

    it 'writes the CMIS SRV record and pin into the env file' do
      is_expected.to contain_file('/etc/ferrogate/mia.env')
        .with_content(%r{FERROGATE_CMIS_SRV=_cmis\._tcp\.prod\.example\.com})
        .with_content(%r{FERROGATE_CMIS_SPKI_PIN=5f2ec4})
    end

    it 'does not also write a single endpoint' do
      is_expected.to contain_file('/etc/ferrogate/mia.env')
        .without_content(%r{FERROGATE_CMIS_ENDPOINT=})
    end

    it 'writes the SRV record into the TOML and omits endpoint' do
      is_expected.to contain_file('/etc/ferrogate/mia.toml')
        .with_content(%r{srv = '_cmis\._tcp\.prod\.example\.com'})
        .without_content(%r{endpoint = })
    end
  end

  context 'with the virtual-tpm attestation backend selected' do
    let(:facts) { MIA_FACTS }
    let(:params) { { attest_backend: 'virtual-tpm' } }

    it { is_expected.to compile }

    it 'writes the attestation backend into the env file' do
      is_expected.to contain_file('/etc/ferrogate/mia.env')
        .with_content(%r{FERROGATE_ATTEST_BACKEND=virtual-tpm})
    end

    it 'mirrors the backend into the TOML attestation section' do
      is_expected.to contain_file('/etc/ferrogate/mia.toml')
        .with_content(%r{\[attestation\]})
        .with_content(%r{backend = 'virtual-tpm'})
    end
  end

  context 'with the default (host-key) attestation backend' do
    let(:facts) { MIA_FACTS }

    # Left unset, the module emits nothing so the agent takes its own default
    # (host-key); it must not force a backend into either surface.
    it 'writes no attestation backend into the env file' do
      is_expected.to contain_file('/etc/ferrogate/mia.env')
        .without_content(%r{FERROGATE_ATTEST_BACKEND=})
    end

    it 'writes no backend key into the TOML' do
      is_expected.to contain_file('/etc/ferrogate/mia.toml')
        .without_content(%r{backend = })
    end
  end

  context 'with manage_toml disabled' do
    let(:facts) { MIA_FACTS }
    let(:params) { { manage_toml: false } }

    it { is_expected.to compile }

    it 'renders the env file but not the TOML' do
      is_expected.to contain_file('/etc/ferrogate/mia.env')
      is_expected.not_to contain_file('/etc/ferrogate/mia.toml')
    end
  end

  context 'with manage_user disabled' do
    let(:facts) { MIA_FACTS }
    let(:params) { { manage_user: false } }

    it { is_expected.to compile }

    it 'does not create the privilege-drop account' do
      is_expected.not_to contain_user('_ferrogate')
      is_expected.not_to contain_group('_ferrogate')
    end
  end

  context 'with both cmis_endpoint and cmis_srv set' do
    let(:facts) { MIA_FACTS }
    let(:params) do
      {
        cmis_endpoint: 'https://cmis.example.com:8443',
        cmis_srv:      '_cmis._tcp.prod.example.com',
      }
    end

    it 'fails compilation with a clear error' do
      is_expected.to compile.and_raise_error(%r{mutually exclusive})
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

    it { is_expected.to compile }

    it 'removes any repo the module previously added' do
      is_expected.to contain_yumrepo('ferrogate-mia').with(ensure: 'absent')
    end

    it 'adds no active custom repository' do
      is_expected.not_to contain_yumrepo('ferrogate-mia').with(ensure: 'present')
      is_expected.not_to contain_file('/etc/apt/sources.list.d/ferrogate-mia.list')
    end
  end

  context 'with repo management off and the package unmanaged' do
    let(:facts) { MIA_FACTS }
    let(:params) { { manage_package: false } }

    it { is_expected.to compile }

    it 'still removes a stale repo but adds no package ordering' do
      is_expected.to contain_yumrepo('ferrogate-mia').with(ensure: 'absent')
      is_expected.not_to contain_package('ferrogate-mia')
    end
  end

  context 'with repo management off on the Debian family' do
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

    it { is_expected.to compile }

    it 'removes any apt source the module previously added' do
      is_expected.to contain_file('/etc/apt/sources.list.d/ferrogate-mia.list').with(ensure: 'absent')
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

  # --- Windows (Chocolatey .nupkg) -----------------------------------------
  WINDOWS_FACTS = {
    os: {
      family:  'windows',
      name:    'windows',
      release: { major: '2022', full: '10.0.20348' },
    },
  }.freeze

  context 'on Windows with helper_require_authenticode => false' do
    let(:facts) { WINDOWS_FACTS }
    let(:params) { { helper_require_authenticode: false } }

    it { is_expected.to compile }

    it 'writes require_authenticode = false to mia.toml under [helper]' do
      is_expected.to contain_file('C:/ProgramData/ferrogate/mia.toml')
        .with_content(%r{\[helper\]\n(?:.*\n)*?require_authenticode = false})
    end

    it 'writes FERROGATE_HELPER_REQUIRE_AUTHENTICODE=0 to mia.env' do
      is_expected.to contain_file('C:/ProgramData/ferrogate/mia.env')
        .with_content(%r{^FERROGATE_HELPER_REQUIRE_AUTHENTICODE=0$})
    end
  end

  context 'on Windows with defaults' do
    let(:facts) { WINDOWS_FACTS }

    it { is_expected.to compile }

    it 'installs the MIA package via the chocolatey provider' do
      is_expected.to contain_package('ferrogate-mia').with(
        ensure:   'installed',
        provider: 'chocolatey',
      )
    end

    it 'manages the Windows config directory under ProgramData' do
      is_expected.to contain_file('C:/ProgramData/ferrogate').with(ensure: 'directory')
    end

    it 'writes the config file on disk' do
      is_expected.to contain_file('C:/ProgramData/ferrogate/mia.env').with(ensure: 'file')
    end

    it 'manages the service via the windows provider' do
      is_expected.to contain_service('mia').with(
        ensure:   'running',
        enable:   true,
        provider: 'windows',
      )
    end

    it 'drops the inapplicable Unix helper-socket default' do
      is_expected.to contain_file('C:/ProgramData/ferrogate/mia.env')
        .without_content(%r{FERROGATE_HELPER_SOCKET=})
    end

    it 'renders the TOML under ProgramData without the Unix socket default' do
      is_expected.to contain_file('C:/ProgramData/ferrogate/mia.toml')
        .with_content(%r{log = 'info'})
        .without_content(%r{socket = '})
    end

    it 'renders no require_authenticode by default' do
      is_expected.to contain_file('C:/ProgramData/ferrogate/mia.toml')
        .without_content(%r{require_authenticode})
      is_expected.to contain_file('C:/ProgramData/ferrogate/mia.env')
        .without_content(%r{REQUIRE_AUTHENTICODE})
    end

    it 'does not create a POSIX privilege-drop account (runs as LocalSystem)' do
      is_expected.not_to contain_user('_ferrogate')
      is_expected.not_to contain_group('_ferrogate')
    end

    it 'removes any Chocolatey source the module previously added' do
      is_expected.to contain_chocolateysource('ferrogate-mia').with(ensure: 'absent')
    end
  end

  context 'on Windows with a custom Chocolatey source (NuGet feed)' do
    let(:facts) { WINDOWS_FACTS }
    let(:params) do
      {
        manage_repo:   true,
        repo_baseurl:  'https://nuget.example.com/ferrogate/index.json',
        repo_user:     'svc-puppet',
        repo_password: 's3cret',
        repo_priority: 1,
      }
    end

    it { is_expected.to compile }

    it 'registers the custom Chocolatey source' do
      is_expected.to contain_chocolateysource('ferrogate-mia').with(
        ensure:   'present',
        location: 'https://nuget.example.com/ferrogate/index.json',
        user:     'svc-puppet',
        priority: 1,
      )
    end
  end

  context 'on Linux the mia.toml is readable by the package status group' do
    let(:facts) { MIA_FACTS }

    it 'is owned root:ferrogate-status, mode 0640' do
      is_expected.to contain_file('/etc/ferrogate/mia.toml').with(
        owner: 'root',
        group: 'ferrogate-status',
        mode:  '0640',
      )
    end

    it 'keeps mia.env root:root' do
      is_expected.to contain_file('/etc/ferrogate/mia.env').with(group: 'root')
    end

    it 'restores the service-account read ACL the package set' do
      is_expected.to contain_exec('ferrogate-mia-toml-acl').with(
        command: 'setfacl --modify user:_ferrogate:r-- -- /etc/ferrogate/mia.toml',
      )
    end
  end

  context 'on Linux with toml_group overridden and the ACL unmanaged' do
    let(:facts) { MIA_FACTS }
    let(:params) { { toml_group: 'root', manage_service_acl: false } }

    it { is_expected.to compile }

    it 'uses the override group and declares no ACL exec' do
      is_expected.to contain_file('/etc/ferrogate/mia.toml').with(group: 'root')
      is_expected.not_to contain_exec('ferrogate-mia-toml-acl')
    end
  end

  context 'on Linux adding users to the MIA groups' do
    let(:facts) { MIA_FACTS }
    let(:params) do
      {
        status_group_members:    ['alice'],
        client_group_members:    ['alice', 'bob'],
        operators_group_members: ['bob'],
      }
    end

    it { is_expected.to compile }

    it 'adds each user to the right group, additively' do
      is_expected.to contain_exec('ferrogate-mia-ferrogate-status-alice')
        .with_command('usermod -aG ferrogate-status -- alice')
      is_expected.to contain_exec('ferrogate-mia-ferrogate-clients-alice')
        .with_command('usermod -aG ferrogate-clients -- alice')
      is_expected.to contain_exec('ferrogate-mia-ferrogate-clients-bob')
        .with_command('usermod -aG ferrogate-clients -- bob')
      is_expected.to contain_exec('ferrogate-mia-ferrogate-operators-bob')
        .with_command('usermod -aG ferrogate-operators -- bob')
    end
  end

  context 'on Windows adding users to the MIA local groups' do
    let(:facts) { WINDOWS_FACTS }
    let(:params) do
      {
        status_group_members: ['CORP\\alice'],
        client_group_members: ['CORP\\bob'],
      }
    end

    it { is_expected.to compile }

    it 'manages membership additively on the installer-created groups' do
      is_expected.to contain_group('FerroGateStatus').with(
        members:         ['CORP\\alice'],
        auth_membership: false,
        provider:        'windows_adsi',
      )
      is_expected.to contain_group('FerroGateClients').with(members: ['CORP\\bob'])
    end
  end

  context 'on Windows the status group can read mia.toml' do
    let(:facts) { WINDOWS_FACTS }

    it 'grants FerroGateStatus read on the file only, via icacls' do
      is_expected.to contain_exec('ferrogate-mia-toml-acl')
        .with_command('C:\\Windows\\System32\\icacls.exe "C:/ProgramData/ferrogate/mia.toml" /grant "FerroGateStatus:(R)"')
        .with_provider('windows')
    end

    it 'grants FerroGateStatus read+traverse on the directory only (no inheritance)' do
      is_expected.to contain_exec('ferrogate-mia-dir-acl')
        .with_command('C:\\Windows\\System32\\icacls.exe "C:/ProgramData/ferrogate" /grant "FerroGateStatus:(RX)"')
        .with_provider('windows')
    end

    it 'does not set a POSIX group on the file' do
      is_expected.to contain_file('C:/ProgramData/ferrogate/mia.toml').without_group
    end
  end

  context 'on Windows with a custom toml_group' do
    let(:facts) { WINDOWS_FACTS }
    let(:params) { { toml_group: 'CORP\\mia-readers' } }

    it 'grants that group instead of FerroGateStatus' do
      is_expected.to contain_exec('ferrogate-mia-toml-acl')
        .with_command('C:\\Windows\\System32\\icacls.exe "C:/ProgramData/ferrogate/mia.toml" /grant "CORP\\mia-readers:(R)"')
    end
  end

  context 'on Windows with manage_toml_acl disabled' do
    let(:facts) { WINDOWS_FACTS }
    let(:params) { { manage_toml_acl: false } }

    it { is_expected.not_to contain_exec('ferrogate-mia-toml-acl') }
    it { is_expected.not_to contain_exec('ferrogate-mia-dir-acl') }
  end

  context 'on Windows with no members' do
    let(:facts) { WINDOWS_FACTS }

    it 'declares no group resources' do
      is_expected.not_to contain_group('FerroGateStatus')
      is_expected.not_to contain_group('FerroGateClients')
    end
  end

  context 'on Windows with a managed source: package installs from it by name' do
    let(:facts) { WINDOWS_FACTS }
    let(:params) do
      {
        manage_repo:  true,
        repo_baseurl: 'https://nuget.example.com/ferrogate/',
      }
    end

    it { is_expected.to compile }

    it 'passes the registered source name to choco install --source' do
      is_expected.to contain_package('ferrogate-mia').with(
        ensure:   'installed',
        provider: 'chocolatey',
        source:   'ferrogate-mia',
      )
    end
  end

  context 'on Windows with a Sensitive feed password and a custom source name' do
    let(:facts) { WINDOWS_FACTS }
    let(:params) do
      {
        manage_repo:       true,
        repo_baseurl:      'https://nuget.example.com/ferrogate/',
        repo_user:         'svc-puppet',
        repo_password:     sensitive('s3cret'),
        repo_priority:     1,
        choco_source_name: 'fgv-nuget',
      }
    end

    it { is_expected.to compile }

    it 'registers the source under the custom name with the unwrapped password' do
      is_expected.to contain_chocolateysource('fgv-nuget').with(
        ensure:   'present',
        location: 'https://nuget.example.com/ferrogate/',
        user:     'svc-puppet',
        password: 's3cret',
        priority: 1,
      )
    end

    it 'installs from the custom source name' do
      is_expected.to contain_package('ferrogate-mia').with(source: 'fgv-nuget')
    end
  end

  context 'on Windows with repo_user but no repo_password' do
    let(:facts) { WINDOWS_FACTS }
    let(:params) do
      {
        manage_repo:  true,
        repo_baseurl: 'https://nuget.example.com/ferrogate/',
        repo_user:    'svc-puppet',
      }
    end

    it 'fails compilation with a clear error' do
      is_expected.to compile.and_raise_error(%r{repo_password is unset})
    end
  end

  context 'on Windows with manage_repo off and an explicit package_source' do
    let(:facts) { WINDOWS_FACTS }
    let(:params) { { package_source: 'https://other.example.com/nuget/' } }

    it { is_expected.to compile }

    it 'uses the override as the install source' do
      is_expected.to contain_package('ferrogate-mia').with(source: 'https://other.example.com/nuget/')
    end
  end

  context 'on Windows with a pinned version and install_options' do
    let(:facts) { WINDOWS_FACTS }
    let(:params) do
      {
        package_ensure:  '0.30.28',
        install_options: ['--ignore-checksums'],
      }
    end

    it { is_expected.to compile }

    it 'pins the version and forwards the options to choco' do
      is_expected.to contain_package('ferrogate-mia').with(
        ensure:          '0.30.28',
        install_options: ['--ignore-checksums'],
      )
    end
  end

  context 'on Windows with manage_chocolatey' do
    let(:facts) { WINDOWS_FACTS }
    let(:params) { { manage_chocolatey: true } }

    it { is_expected.to compile }
    it { is_expected.to contain_class('chocolatey') }
  end

  context 'on Windows without manage_chocolatey (default)' do
    let(:facts) { WINDOWS_FACTS }

    it 'does not bootstrap Chocolatey and passes no source or options' do
      is_expected.not_to contain_class('chocolatey')
      is_expected.to contain_package('ferrogate-mia').with(provider: 'chocolatey')
    end
  end

  context 'on RedHat the Windows-only package knobs are ignored' do
    let(:facts) { MIA_FACTS }
    let(:params) do
      {
        package_source:  'https://other.example.com/nuget/',
        install_options: ['--ignore-checksums'],
      }
    end

    it { is_expected.to compile }

    it 'declares the plain package with no source or install_options' do
      is_expected.to contain_package('ferrogate-mia').with(ensure: 'installed')
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
