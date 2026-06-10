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
  context 'with podman defaults (CMIS only; MIA off)' do
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

    it 'registers the subordinate UID/GID range through baseapp (single owner)' do
      is_expected.to contain_baseapp__subid('ferrogate').with(
        subid: 655_425_536,
        count: 65_536,
      )
      is_expected.to contain_concat__fragment('baseapp-subuid-ferrogate').with(
        target:  '/etc/subuid',
        content: 'ferrogate:655425536:65536',
      )
      is_expected.to contain_concat('/etc/subuid')
      is_expected.to contain_concat('/etc/subgid')
    end

    it 'migrates podman storage before pulling so the new subids take effect' do
      is_expected.to contain_exec('ferrogate-podman-migrate').with(
        command: 'podman system migrate',
        user:    'ferrogate',
      )
      is_expected.to contain_exec('ferrogate-pull-image').that_requires('Exec[ferrogate-podman-migrate]')
    end

    it 'pulls the image rootless as the service user from its own home dir' do
      is_expected.to contain_exec('ferrogate-pull-image').with(
        command: 'podman pull ferrogate:latest',
        user:    'ferrogate',
        cwd:     '/home/ferrogate',
      )
    end

    it 'declares the baseapp directory layout' do
      is_expected.to contain_class('baseapp')
    end

    # config/data roots stay owned by the login user.
    ['/srv/application-config/ferrogate',
     '/srv/application-data/ferrogate'].each do |dir|
      it "manages directory #{dir} owned by the login user" do
        is_expected.to contain_file(dir).with(
          ensure: 'directory',
          owner:  'ferrogate',
          group:  'ferrogate',
          mode:   '0750',
        )
      end
    end

    # Bind-mounted volumes are owned by the host id the rootless container's
    # internal uid/gid (10001) maps to: subid_start (10001*65536) + 10001 - 1.
    ['/srv/application-data/ferrogate/audit',
     '/srv/application-data/ferrogate/raft',
     '/srv/application-data/ferrogate/issuer',
     '/srv/application-logs/ferrogate'].each do |dir|
      it "manages volume directory #{dir} owned by the container-mapped id" do
        is_expected.to contain_file(dir).with(
          ensure: 'directory',
          owner:  655_435_536,
          group:  655_435_536,
          mode:   '0750',
        )
      end
    end

    it 'creates the container-mapped owner account' do
      is_expected.to contain_group('ferrogate-pod').with(gid: 655_435_536, system: true)
      is_expected.to contain_user('ferrogate-pod').with(
        uid:    655_435_536,
        gid:    655_435_536,
        system: true,
      )
    end

    it 'renders the cmis env file but not mia (MIA off by default)' do
      is_expected.to contain_file('/srv/application-config/ferrogate/cmis.env')
      is_expected.not_to contain_file('/srv/application-config/ferrogate/mia.env')
    end

    it 'declares a cmis instance that publishes the gRPC port and mounts the volumes' do
      is_expected.to contain_ferrogate__instance('cmis').with(
        command:  'cmis',
        env_file: '/srv/application-config/ferrogate/cmis.env',
        ports:    ['8443:8443'],
        volumes:  [
          '/srv/application-logs/ferrogate:/opt/ferrogate/logs',
          '/srv/application-data/ferrogate/audit:/var/lib/ferrogate/audit',
          '/srv/application-data/ferrogate/raft:/var/lib/ferrogate/raft',
          '/srv/application-data/ferrogate/issuer:/var/lib/ferrogate/issuer',
          '/srv/application-config/ferrogate/tls:/etc/ferrogate/tls', # TLS on by default
        ],
      )
    end

    it 'does not declare a mia instance by default (CMIS-only image)' do
      is_expected.not_to contain_ferrogate__instance('mia')
    end

    it 'configures SELinux booleans and file contexts' do
      is_expected.to contain_exec('ferrogate-selinux-container_manage_cgroup')
      is_expected.to contain_exec('ferrogate-fcontext-/srv/application-data/ferrogate')
    end

    it 'installs the host-side ferrogate operator CLI wrapper' do
      is_expected.to contain_class('ferrogate::cli')
      is_expected.to contain_file('/usr/local/bin/ferrogate').with(
        owner: 'root',
        group: 'root',
        mode:  '0755',
      )
    end

    it 'orders the CLI after install (so a container-start failure cannot skip it)' do
      is_expected.to contain_class('ferrogate::cli').that_requires('Class[ferrogate::install]')
    end

    it 'execs into the cmis container as the rootless service user' do
      is_expected.to contain_file('/usr/local/bin/ferrogate')
        .with_content(%r{sudo -n -u ferrogate})
        .with_content(%r{XDG_RUNTIME_DIR=/run/user/10001})
        .with_content(%r{/usr/bin/podman exec \$TTY_ARGS "\$CONTAINER"})
        .with_content(%r{ENDPOINT='https://127\.0\.0\.1:8443'}) # TLS on by default
    end

    it 'authorises the ferrogate group to run the CLI via sudoers' do
      is_expected.to contain_file('/etc/sudoers.d/ferrogate-cli').with(
        mode:         '0440',
        validate_cmd: '/usr/sbin/visudo -cf %',
      )
      is_expected.to contain_file('/etc/sudoers.d/ferrogate-cli')
        .with_content(%r{%ferrogate ALL=\(ferrogate\) NOPASSWD:})
        .with_content(%r{/usr/bin/podman exec -i ferrogate-cmis ferrogate \*})
    end
  end

  context 'CMIS TLS (on by default)' do
    let(:facts) { BASE_FACTS }

    it { is_expected.to compile }

    it 'declares the tls class' do
      is_expected.to contain_class('ferrogate::tls')
    end

    it 'creates the bind-mounted tls directory owned by the container-mapped id' do
      is_expected.to contain_file('/srv/application-config/ferrogate/tls').with(
        ensure: 'directory',
        owner:  655_435_536,
        group:  655_435_536,
        mode:   '0750',
      )
    end

    it 'generates a self-signed P-384 certificate when none is supplied' do
      is_expected.to contain_exec('ferrogate-tls-generate').with(
        creates: '/srv/application-config/ferrogate/tls/cmis.crt',
      )
      is_expected.to contain_exec('ferrogate-tls-generate')
        .with_command(%r{openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-384})
        .with_command(%r{-keyout /srv/application-config/ferrogate/tls/cmis\.key})
        .with_command(%r{-out /srv/application-config/ferrogate/tls/cmis\.crt})
    end

    it 'manages the cert and key files owned by the container-mapped id (no content when generated)' do
      is_expected.to contain_file('/srv/application-config/ferrogate/tls/cmis.crt').with(
        owner: 655_435_536,
        mode:  '0640',
      )
      is_expected.to contain_file('/srv/application-config/ferrogate/tls/cmis.key').with(
        owner: 655_435_536,
        mode:  '0640',
      )
    end

    it 'computes and publishes the SPKI pin' do
      is_expected.to contain_exec('ferrogate-tls-spki-pin')
        .with_command(%r{openssl x509 -in /srv/application-config/ferrogate/tls/cmis\.crt -pubkey -noout})
        .with_command(%r{openssl dgst -sha384})
      is_expected.to contain_file('/srv/application-config/ferrogate/cmis.spki-pin.txt').with(
        owner: 'ferrogate',
        mode:  '0644',
      )
    end

    # NOTE: the cmis.env CMIS_TLS_CERT/_KEY lines are rendered by an EPP template
    # whose `.each` loop the Artichoke test evaluator cannot render faithfully
    # (it emits `undef=undef`), so the env *content* is not asserted here. The
    # paths fed into the template are exercised via the bind-mount below.

    it 'bind-mounts the tls directory into the cmis container' do
      is_expected.to contain_ferrogate__instance('cmis').with(
        volumes: [
          '/srv/application-logs/ferrogate:/opt/ferrogate/logs',
          '/srv/application-data/ferrogate/audit:/var/lib/ferrogate/audit',
          '/srv/application-data/ferrogate/raft:/var/lib/ferrogate/raft',
          '/srv/application-data/ferrogate/issuer:/var/lib/ferrogate/issuer',
          '/srv/application-config/ferrogate/tls:/etc/ferrogate/tls',
        ],
      )
    end

    it 'points the operator CLI at an https loopback endpoint' do
      is_expected.to contain_file('/usr/local/bin/ferrogate')
        .with_content(%r{ENDPOINT='https://127\.0\.0\.1:8443'})
    end
  end

  context 'allowlist proposal policy' do
    let(:facts) { BASE_FACTS }

    it 'defaults to bootstrap (on) and still renders the cmis env file' do
      is_expected.to compile
      is_expected.to contain_file('/srv/application-config/ferrogate/cmis.env')
    end

    %w[off bootstrap always].each do |policy|
      context "with cmis_allowlist_proposals => '#{policy}'" do
        let(:params) { { cmis_allowlist_proposals: policy } }

        it { is_expected.to compile }
        it { is_expected.to contain_file('/srv/application-config/ferrogate/cmis.env') }
      end
    end
  end

  context 'CMIS TLS with a supplied certificate' do
    let(:facts) { BASE_FACTS }
    let(:params) do
      {
        cmis_tls_cert: "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n",
        cmis_tls_key:  "-----BEGIN PRIVATE KEY-----\nMIGH\n-----END PRIVATE KEY-----\n",
      }
    end

    it { is_expected.to compile }

    it 'does not generate a certificate' do
      is_expected.not_to contain_exec('ferrogate-tls-generate')
    end

    it 'writes the supplied PEM cert and key verbatim' do
      is_expected.to contain_file('/srv/application-config/ferrogate/tls/cmis.crt')
        .with_content(%r{BEGIN CERTIFICATE})
      is_expected.to contain_file('/srv/application-config/ferrogate/tls/cmis.key')
        .with_content(%r{BEGIN PRIVATE KEY})
    end

    it 'still computes the SPKI pin from the supplied cert' do
      is_expected.to contain_exec('ferrogate-tls-spki-pin')
    end
  end

  context 'CMIS TLS disabled (plaintext bring-up)' do
    let(:facts) { BASE_FACTS }
    let(:params) { { cmis_tls_enable: false } }

    it { is_expected.to compile }

    it 'does not declare the tls class or any tls material' do
      is_expected.not_to contain_class('ferrogate::tls')
      is_expected.not_to contain_file('/srv/application-config/ferrogate/tls')
      is_expected.not_to contain_exec('ferrogate-tls-generate')
    end

    it 'does not mount a tls volume into the cmis container' do
      is_expected.to contain_ferrogate__instance('cmis').with(
        volumes: [
          '/srv/application-logs/ferrogate:/opt/ferrogate/logs',
          '/srv/application-data/ferrogate/audit:/var/lib/ferrogate/audit',
          '/srv/application-data/ferrogate/raft:/var/lib/ferrogate/raft',
          '/srv/application-data/ferrogate/issuer:/var/lib/ferrogate/issuer',
        ],
      )
    end

    it 'points the operator CLI back at an http loopback endpoint' do
      is_expected.to contain_file('/usr/local/bin/ferrogate')
        .with_content(%r{ENDPOINT='http://127\.0\.0\.1:8443'})
    end
  end

  context 'CMIS TLS enabled with no cert and generation disabled' do
    let(:facts) { BASE_FACTS }
    let(:params) { { cmis_tls_manage_cert: false } }

    it 'fails compilation with a clear error' do
      is_expected.to compile.and_raise_error(%r{no certificate was supplied})
    end
  end

  context 'with an environment variant' do
    let(:facts) { BASE_FACTS }
    let(:params) { { app_environment: 'staging' } }

    it { is_expected.to compile }

    it 'nests directories under the environment variant' do
      is_expected.to contain_file('/srv/application-config/ferrogate/staging').with(ensure: 'directory')
      is_expected.to contain_file('/srv/application-data/ferrogate/staging/audit').with(ensure: 'directory')
      is_expected.to contain_file('/srv/application-data/ferrogate/staging/raft').with(ensure: 'directory')
      is_expected.to contain_file('/srv/application-data/ferrogate/staging/issuer').with(ensure: 'directory')
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

    it 'installs a docker-flavoured CLI wrapper and sudoers entry' do
      is_expected.to contain_file('/usr/local/bin/ferrogate')
        .with_content(%r{/usr/bin/docker exec \$TTY_ARGS "\$CONTAINER"})
      is_expected.to contain_file('/etc/sudoers.d/ferrogate-cli')
        .with_content(%r{%ferrogate ALL=\(root\) NOPASSWD:})
        .with_content(%r{/usr/bin/docker exec -i ferrogate-cmis ferrogate \*})
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

  context 'with mia explicitly enabled' do
    let(:facts) { BASE_FACTS }
    let(:params) { { mia_enable: true } }

    it { is_expected.to compile }

    it 'renders the mia env file' do
      is_expected.to contain_file('/srv/application-config/ferrogate/mia.env')
    end

    it 'declares a mia instance with the TPM device' do
      is_expected.to contain_ferrogate__instance('mia').with(
        command: 'mia',
        devices: ['/dev/tpmrm0'],
      )
    end
  end

  context 'with subid management disabled' do
    let(:facts) { BASE_FACTS }
    let(:params) { { manage_subids: false } }

    it { is_expected.to compile }

    it 'does not register a baseapp::subid (an operator/another module owns it)' do
      is_expected.not_to contain_baseapp__subid('ferrogate')
    end
  end

  context 'with only cmis enabled' do
    let(:facts) { BASE_FACTS }
    let(:params) { { mia_enable: false } }

    it { is_expected.to compile }

    it 'still renders the cmis env file' do
      is_expected.to contain_file('/srv/application-config/ferrogate/cmis.env')
    end

    it 'still installs the operator CLI wrapper' do
      is_expected.to contain_file('/usr/local/bin/ferrogate')
    end
  end

  context 'with cmis disabled' do
    let(:facts) { BASE_FACTS }
    let(:params) { { cmis_enable: false } }

    it { is_expected.to compile }

    it 'does not install the operator CLI wrapper (no server to talk to)' do
      is_expected.not_to contain_class('ferrogate::cli')
      is_expected.not_to contain_file('/usr/local/bin/ferrogate')
    end
  end
end
