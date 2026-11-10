# @summary Deploy FerroGate (CMIS and/or MIA) as rootless containers.
#
# Installs and runs the FerroGate machine-identity services from a container
# image, managed by systemd. When the chosen runtime is **podman** the services
# are described as rootless [Quadlet](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)
# `.container` units owned by a dedicated unprivileged user; when it is
# **docker** a plain system `systemd` unit wraps `docker run`. SELinux is
# configured so the bind-mounted host directories are reachable by the
# container.
#
# On-disk layout builds on the {ffquintella-baseapp} module: every FerroGate
# directory lives under the baseapp roots
# (`/srv/application-{config,data,logs}`) below a `ferrogate` sub-directory and,
# optionally, an *environment variant* sub-directory (empty by default).
#
#   /srv/application-config/ferrogate[/<app_environment>]
#   /srv/application-data/ferrogate[/<app_environment>]/audit
#   /srv/application-logs/ferrogate[/<app_environment>]
#
# @param runtime
#   Container runtime to use. `'auto'` resolves to the
#   `$facts['ferrogate_container_runtime']` fact (podman preferred over docker).
# @param manage_runtime
#   Whether to install the selected runtime package.
# @param registry
#   Optional registry host (and namespace) the image is pulled from, e.g.
#   `'ghcr.io/felipe-quintella'`. When `undef`/empty the bare
#   `<image_name>:<image_tag>` reference is used.
# @param image_name
#   Image repository name.
# @param image_tag
#   Image tag to deploy.
# @param pull_image
#   Whether to pull the image during the Puppet run.
# @param app_environment
#   Environment-variant sub-directory appended after `ferrogate` in every
#   baseapp root. Empty by default (no extra level).
# @param user
#   Dedicated unprivileged user that owns the directories and (for podman) runs
#   the rootless containers.
# @param group
#   Primary group for the dedicated user.
# @param uid
#   UID for the dedicated user. Matches the image's built-in user (10001).
# @param gid
#   GID for the dedicated group.
# @param manage_user
#   Whether to manage the dedicated user/group. For podman this also creates a
#   companion `<user>-pod` account whose uid/gid is the *mapped* id the rootless
#   container's internal user resolves to (`subid_start + uid - 1`); the
#   bind-mounted log/audit volumes are owned by it so the non-root container can
#   write them. (Rootless podman remaps the container's internal uid to a
#   subordinate id, so the login user — which only owns container id 0 — cannot
#   own the volumes; `keep-id`, which would avoid the remap, is broken on
#   podman 5.x + EL10/UEK.)
# @param manage_subids
#   Whether to register the dedicated user's rootless subordinate UID/GID range
#   (`/etc/subuid`, `/etc/subgid`) through `baseapp::subid`. **Defaults to
#   `true`.** baseapp owns those files as concat targets, so every rootless app
#   on the node (e.g. ferrogate + bastionvault) contributes one fragment and
#   they stop fighting over the files. Set `false` if an operator or another
#   module manages the ranges. Ignored for the docker runtime.
#
#   **Single owner:** baseapp must be the only manager of `/etc/subuid` /
#   `/etc/subgid`. If the `puppet/podman` module is also on the node, leave its
#   `manage_subuid => false` (the default) so it does not declare a competing
#   `Concat['/etc/subuid']`.
# @param subid_start
#   First subordinate id for the dedicated user. Defaults to `uid * 65536`, a
#   deterministic per-user block that does not overlap other users' ranges.
# @param subid_count
#   Size of the subordinate id block. Defaults to 65536.
# @param manage_selinux
#   Whether to apply SELinux configuration (no-op when SELinux is disabled).
# @param selinux_relabel
#   Volume relabel mode appended to bind mounts: `'Z'` (private),
#   `'z'` (shared) or `'none'`.
# @param rust_log
#   Value of the `RUST_LOG` tracing filter passed to every service.
# @param cmis_enable
#   Deploy the CMIS (Central Machine Identity Service) instance.
# @param cmis_listen
#   `CMIS_LISTEN` socket address inside the container.
# @param cmis_trust_domain
#   `CMIS_TRUST_DOMAIN` — the SPIFFE trust domain CMIS stamps into the SVIDs and
#   allowlists it issues (e.g. `'ferrogate.prod'`). `undef` (the default) leaves
#   the var unset, so the binary falls back to its built-in `ferrogate.dev`.
#   **Must stay constant for a given issuer seed**: changing it after a cluster
#   has established its seed re-scopes every issued identity, so set it once at
#   bring-up and treat it as immutable thereafter.
# @param cmis_port
#   Host port published for CMIS (mapped to `cmis_container_port`).
# @param cmis_container_port
#   Container-side port CMIS listens on. Must match the port in `cmis_listen`.
# @param cmis_allowlist_proposals
#   `CMIS_ALLOWLIST_PROPOSALS` — how CMIS treats host-driven allowlist proposals
#   submitted via the `ProposeAllowlist` RPC (MIA proposes the local callers it
#   observes so a freshly installed host can bootstrap its own allowlist). All
#   proposals are verified (SVID + signature) regardless; this only governs
#   whether an accepted proposal becomes the live allowlist on its own:
#   - `'off'` — never auto-adopt; every proposal queues for operator review.
#   - `'bootstrap'` — **default, on** — auto-adopt only when the host has no
#     allowlist yet (first-use TOFU); any change to an existing allowlist queues
#     for review.
#   - `'always'` — auto-adopt every accepted proposal, including changes to an
#     existing allowlist. Most convenient, weakest.
# @param cmis_svid_ttl_secs
#   `CMIS_SVID_TTL_SECS` (CMIS ≥ 0.19.12) — lifetime, in seconds, of the SVIDs
#   CMIS issues. `undef` (the default) leaves the var unset so the binary keeps
#   its built-in default of 30 days. The binary floors the value at 96 h and
#   caps it at 30 days; this parameter's type (`Integer[345600, 2592000]`)
#   enforces the same `[96 h, 30 d]` window at catalog compile so an
#   out-of-range value fails fast rather than being silently clamped.
# @param cmis_allowlist_ttl_secs
#   `CMIS_ALLOWLIST_TTL_SECS` (CMIS ≥ 0.19.12) — validity window, in seconds, of
#   the signed caller-allowlists CMIS issues. `undef` (the default) leaves the
#   var unset so the binary keeps its built-in default of 96 h. Same
#   `[96 h, 30 d]` range as `cmis_svid_ttl_secs`. **Must not exceed the MIA's
#   `allowlist.max_age_secs`** (`FERROGATE_ALLOWLIST_MAX_AGE_SECS`, also 96 h by
#   default) — a freshly signed list older than the consumer's window is
#   rejected as stale, so raise both together if you lengthen it.
# @param cmis_admin_pepper_file
#   `CMIS_ADMIN_PEPPER_FILE` — **in-container** path of the pepper file mixed
#   into admin password hashes. `undef` (the default) leaves it unset, in which
#   case CMIS hashes admin passwords without a pepper. The file must be
#   identical on every node of a cluster and is provisioned out of band; the
#   persistent admin directory (`/srv/application-data/ferrogate[/<env>]/admin`,
#   mounted at `/var/lib/ferrogate/admin`) is a convenient place for it. Set it
#   **before** enrolling the first administrator: changing it afterwards
#   invalidates existing admin password hashes.
# @param cmis_admin_password_blocklist_file
#   `CMIS_ADMIN_PASSWORD_BLOCKLIST_FILE` — **in-container** path of a password
#   blocklist checked on admin password changes, in addition to the small
#   embedded list. `undef` (the default) leaves it unset. Provision it out of
#   band, identically on every node.
# @param cmis_admin_listen
#   `CMIS_ADMIN_LISTEN` — socket address (inside the container) of the dedicated
#   admin listener that serves the `Admin` gRPC service (login, accounts,
#   sessions, enrollment). `undef` (the default) leaves it unset, so CMIS keeps
#   its built-in `127.0.0.1:8444`: reachable only from the host itself (e.g. over
#   an SSH tunnel). The `Admin` service is **never** served on the main listener
#   (`cmis_listen`); it answers `UNIMPLEMENTED admin_listener_only` there, so a
#   remote admin client (CLI, tray admin app) can only work against this
#   listener. Set it to `'0.0.0.0:8444'` to make it reachable from the network.
#   **This widens the administrative attack surface**: restrict the port with a
#   host firewall to the management network and prefer `CMIS_ADMIN_CLIENT_CA`
#   (mTLS). Clients pin the certificate's SPKI, so the admin listener should use
#   the same certificate as the main one (the default).
# @param cmis_admin_port
#   Host and container port published for the admin listener on a **single-node**
#   (rootless `pasta`) deployment, and only when `cmis_admin_listen` is set. Must
#   match the port in `cmis_admin_listen`. Ignored on a multi-node cluster, which
#   uses host networking and binds the address directly.
# @param cmis_cluster_peers
#   CMIS High Availability (F05) — the Raft peer set this node belongs to. CMIS
#   keeps every durable store (issued SVIDs, host allowlists, pending allowlist
#   proposals) in a hiqlite-backed Raft state machine under `raft_dir`. Leave
#   this **empty (the default)** to run a self-bootstrapping **single-node**
#   cluster (the node is its own only peer, elects itself leader, and never
#   looks for others) — state still persists across restarts.
#
#   To run a **multi-node** cluster, give every peer (including this node) as a
#   `node_id => { 'raft_addr' => 'host:port', 'api_addr' => 'host:port' }` entry
#   and set `cmis_node_id` to this node's id. The `raft_addr`/`api_addr` are the
#   addresses peers *dial*, so they must be routable from the other nodes
#   (hostnames or stable IPs, never loopback). The module renders these as
#   `CMIS_CLUSTER_PEERS` (`id=raft_addr,api_addr` joined by `;`). A multi-node
#   cluster also **requires** matching `cmis_raft_secret` / `cmis_api_secret`
#   shared across the fleet.
#
#   **Networking:** CMIS (≥ 0.18.11) binds its Raft/API transports on
#   `cmis_raft_listen` (`0.0.0.0`) in multi-node mode, and hiqlite's leader dials
#   its own advertised address. Rootless `pasta` cannot hairpin a published port
#   back into its own container, so the module runs the multi-node CMIS container
#   with **host networking** (set automatically) — the transports bind directly
#   on the host. Secure the inter-node link with `cmis_peer_tls` (on by default)
#   unless the peers share a trusted private network. Keep peers within ~80 ms of
#   each other — Raft commit latency is on the issuance path.
# @param cmis_node_id
#   This node's id within `cmis_cluster_peers`. Required (and must be a key of
#   that hash) when `cmis_cluster_peers` is non-empty; ignored for a single-node
#   cluster. Renders `CMIS_NODE_ID`.
# @param cmis_raft_port
#   Port for the inter-node Raft transport. Used to build the single-node
#   `CMIS_RAFT_ADDR` (`127.0.0.1:<port>`) and, in a multi-node cluster, the port
#   peers dial for this node's Raft transport (bound on `cmis_raft_listen` via
#   host networking).
# @param cmis_api_port
#   Port for the Raft management / forwarding API transport. Used for the
#   single-node `CMIS_API_ADDR` and, in a multi-node cluster, the port peers dial
#   for this node's management API.
# @param cmis_raft_secret
#   Shared secret for the inter-node Raft transport (`CMIS_RAFT_SECRET`). Must be
#   at least 16 characters and identical on every node. **Required** for a
#   multi-node cluster; ignored (the binary uses loopback-only dev secrets) for
#   a single-node cluster. Written to the `0640` env file in plaintext.
# @param cmis_api_secret
#   Shared secret for the Raft management API transport (`CMIS_API_SECRET`).
#   Same rules as `cmis_raft_secret`.
# @param cmis_raft_listen
#   Interface the multi-node Raft + management transports **bind**
#   (`CMIS_RAFT_LISTEN`). Defaults to `0.0.0.0` (all interfaces) so peers on
#   other hosts can reach this node; the *advertised* address each peer dials is
#   still its `cmis_cluster_peers` entry. Only rendered for a multi-node cluster
#   (single-node binds loopback). Set to a specific host IP to bind one NIC.
# @param cmis_raft_heartbeat_ms
#   Raft heartbeat in ms (`CMIS_RAFT_HEARTBEAT_MS`); also the time-to-live of
#   each `AppendEntries` call. `undef` (default) renders nothing and keeps the
#   CMIS default (500). Raise it, with both election timeouts, when a slow or
#   lossy peer link makes a healthy two-node cluster report `not enough for a
#   quorum`. Multi-node only; must be identical on every node.
# @param cmis_raft_election_min_ms
#   Shortest Raft election timeout in ms (`CMIS_RAFT_ELECTION_MIN_MS`). `undef`
#   keeps the default (1500). Must be at least 3 x the effective heartbeat.
# @param cmis_raft_election_max_ms
#   Longest Raft election timeout in ms (`CMIS_RAFT_ELECTION_MAX_MS`, at most
#   300000). `undef` keeps the default (3000). Must exceed the minimum.
# @param cmis_raft_allow_aggressive_timeouts
#   Render `CMIS_RAFT_ALLOW_AGGRESSIVE_TIMEOUTS=true`, which CMIS requires for a
#   heartbeat below 500 or an election minimum below 1500. Only rendered when
#   true.
# @param cmis_peer_tls
#   Encrypt the inter-node Raft + management transport with TLS
#   (`CMIS_PEER_TLS=1`) — hiqlite's rustls transport with auto-generated
#   self-signed certs, authenticated by the shared `cmis_raft_secret` /
#   `cmis_api_secret` handshake (the secret never crosses the wire). Defaults to
#   `true`; recommended whenever peers are not on a trusted private network.
#   Ignored for a single-node cluster, and superseded by `cmis_peer_tls_cert` /
#   `cmis_peer_tls_key` when those are set.
# @param cmis_peer_tls_cert
#   In-container path to an operator-supplied PEM certificate for the inter-node
#   transport (`CMIS_PEER_TLS_CERT`), for a stable cert across restarts instead
#   of the per-process self-signed one. Must be set together with
#   `cmis_peer_tls_key`; the operator is responsible for making the path
#   readable inside the container (e.g. via the TLS bind mount). `undef` leaves
#   the self-signed path (`cmis_peer_tls`).
# @param cmis_peer_tls_key
#   In-container path to the PEM private key paired with `cmis_peer_tls_cert`
#   (`CMIS_PEER_TLS_KEY`). Must be set together with it.
# @param cmis_peer_ca_manage
#   Manage a CA-issued certificate for the inter-node transport (default `true`).
#   When a multi-node cluster has `cmis_peer_tls` on and no operator-supplied leaf
#   (`cmis_peer_tls_cert`/`_key`), the module issues this node's leaf from a CA
#   and points the container's TLS verifier at that CA via `SSL_CERT_FILE` — see
#   `ferrogate::peer_ca`. This is what lets hiqlite's split-brain / cluster-metrics
#   client (which uses rustls' platform verifier, not the shared-secret handshake)
#   accept the peer certificate instead of failing `UnknownIssuer`. Set `false` to
#   fall back to the bare self-signed `CMIS_PEER_TLS=1` transport. Requires
#   OpenSSL ≥ 3.0 on the host. Ignored for a single-node cluster, when
#   `cmis_peer_tls` is `false`, or when an operator leaf pair is supplied.
# @param cmis_peer_ca_cert
#   PEM certificate of the CA that signs the inter-node leaf, as a string. **This
#   is how a multi-node fleet shares one trust anchor:** give every node the same
#   `cmis_peer_ca_cert`/`cmis_peer_ca_key` (the key via eyaml) so each node's leaf
#   chains to a CA all the others trust. When `undef`, the module generates a
#   self-signed local CA — mutually trusted only on a single-node cluster unless
#   you distribute the generated material to every peer. Set both
#   `cmis_peer_ca_cert` and `cmis_peer_ca_key` together, or neither.
# @param cmis_peer_ca_key
#   PEM private key (EC/PKCS#8) for `cmis_peer_ca_cert`, as a string. Written
#   host-only (`0600`, never mounted into the container) and used to sign this
#   node's leaf. Set together with `cmis_peer_ca_cert`.
# @param cmis_peer_ca_days
#   Validity in days for a generated CA **and** for the issued leaf. Ignored for a
#   supplied CA's own validity (the leaf it signs still uses this). Default 3650.
# @param cmis_peer_cert_san
#   Extra `subjectAltName` entries for the issued leaf, each a raw OpenSSL SAN
#   token (e.g. `'DNS:cmis2.example.com'`, `'IP:10.0.0.2'`). The node FQDN is
#   always added as a `DNS:` SAN. Add the address peers actually dial here when it
#   is not the FQDN — rustls matches the dialed name against the leaf SAN.
# @param cmis_tls_enable
#   Terminate **hybrid-PQC TLS** (TLS 1.3, `X25519MLKEM768`-only) on the CMIS
#   listener. When `true` (the default) the module sets `CMIS_TLS_CERT` /
#   `CMIS_TLS_KEY` for the container and ensures a certificate exists (supplied
#   or generated — see `cmis_tls_cert`/`cmis_tls_manage_cert`). When `false`
#   CMIS runs the **plaintext bring-up server** — dev only; never in production.
#   FerroGate authenticates the server by **SPKI pin**, not a CA chain, so a
#   self-signed certificate is fine; the module also publishes the pin (see
#   below) for configuring MIA clients.
#
#   **Caveat:** the in-container operator CLI (`/usr/local/bin/ferrogate`) is a
#   plaintext gRPC client today. With TLS on, the wrapper points it at an
#   `https://` loopback endpoint; it works only against a `ferrogate` CLI build
#   that speaks the F01 hybrid-PQC transport. On an older CLI, run operator
#   commands against a node with TLS off, or use a TLS-aware client.
# @param cmis_tls_cert
#   PEM certificate chain for the CMIS listener (end-entity first, then any
#   intermediates), as a string. When set, `cmis_tls_key` must also be set and
#   the pair is written to disk verbatim (no generation). When `undef` and
#   `cmis_tls_manage_cert` is `true`, a self-signed certificate is generated.
# @param cmis_tls_key
#   PEM private key (PKCS#8, PKCS#1 or SEC1) matching `cmis_tls_cert`, as a
#   string. Set both `cmis_tls_cert` and `cmis_tls_key` together, or neither.
# @param cmis_tls_manage_cert
#   When TLS is enabled and no certificate is supplied, generate a self-signed
#   P-384 certificate with OpenSSL on the node (idempotent — only created if the
#   cert file is absent). Set `false` to require an operator-supplied cert and
#   fail the run if none is present. Requires `openssl` on the host. Ignored
#   when `cmis_tls_cert`/`cmis_tls_key` are supplied.
# @param cmis_tls_cert_cn
#   Common Name (subject) for the generated self-signed certificate. Defaults to
#   the node FQDN fact, falling back to `cmis.ferrogate.internal`. The hostname
#   is irrelevant to trust (SPKI pinning) — it is used only for SNI/routing.
# @param cmis_tls_cert_days
#   Validity in days for the generated self-signed certificate. Ignored for a
#   supplied certificate.
# @param mia_enable
#   Deploy the MIA (Machine Identity Agent) as a container. **Defaults to
#   `false`**: the standard FerroGate image is CMIS-only — it ships the `cmis`
#   server and the `ferrogate` CLI but no `mia` binary, and its entrypoint
#   expects MIA to be installed on the host from its OS package rather than run
#   in a container. Only enable this against an image that actually bundles
#   `mia`, on a host prepared for the MIA hardening profile.
# @param mia_tpm_device
#   Host TPM resource-manager device handed to the MIA container.
# @param mia_skip_hardening
#   Set `FERROGATE_SKIP_HARDENING=1` for MIA. The host-hardening profile
#   (enforced IMA, seccomp install, privilege drop) cannot be satisfied inside a
#   generic container, so this defaults to `true`. Set `false` only on a host
#   prepared for the full MIA hardening profile.
# @param extra_env
#   Extra environment variables merged into every instance's env file.
#
# @example Defaults — deploy CMIS with podman, rootless (MIA off; see mia_enable)
#   include ferrogate
#
# @example Pull from a private registry, pin a tag, use docker
#   class { 'ferrogate':
#     runtime    => 'docker',
#     registry   => 'registry.example.com/fgv',
#     image_tag  => '1.4.0',
#   }
#
# @example Per-environment deployment under /srv/.../ferrogate/staging
#   class { 'ferrogate':
#     app_environment => 'staging',
#   }
class ferrogate (
  Enum['auto', 'podman', 'docker'] $runtime            = 'auto',
  Boolean                          $manage_runtime     = true,
  Optional[String[1]]              $registry           = undef,
  String[1]                        $image_name         = 'ferrogate',
  String[1]                        $image_tag          = 'latest',
  Boolean                          $pull_image         = true,
  String                           $app_environment    = '',
  String[1]                        $user               = 'ferrogate',
  String[1]                        $group              = 'ferrogate',
  Integer[0]                       $uid                = 10001,
  Integer[0]                       $gid                = 10001,
  Boolean                          $manage_user        = true,
  Boolean                          $manage_subids      = true,
  Optional[Integer[0]]             $subid_start        = undef,
  Integer[1]                       $subid_count        = 65536,
  Boolean                          $manage_selinux     = true,
  Enum['Z', 'z', 'none']           $selinux_relabel    = 'Z',
  String[1]                        $rust_log           = 'info',
  Boolean                          $cmis_enable        = true,
  String[1]                        $cmis_listen        = '0.0.0.0:8443',
  Optional[String[1]]              $cmis_trust_domain  = undef,
  Stdlib::Port                     $cmis_port          = 8443,
  Stdlib::Port                     $cmis_container_port = 8443,
  Enum['off', 'bootstrap', 'always'] $cmis_allowlist_proposals = 'bootstrap',
  Optional[Integer[345600, 2592000]] $cmis_svid_ttl_secs      = undef,
  Optional[Integer[345600, 2592000]] $cmis_allowlist_ttl_secs = undef,
  Optional[Stdlib::Unixpath]       $cmis_admin_pepper_file = undef,
  Optional[Stdlib::Unixpath]       $cmis_admin_password_blocklist_file = undef,
  Optional[String[1]]              $cmis_admin_listen = undef,
  Stdlib::Port                     $cmis_admin_port = 8444,
  Hash[Integer[1], Struct[{
      'raft_addr' => String[1],
      'api_addr'  => String[1],
  }]]                              $cmis_cluster_peers = {},
  Optional[Integer[1]]             $cmis_node_id       = undef,
  Stdlib::Port                     $cmis_raft_port     = 9601,
  Stdlib::Port                     $cmis_api_port      = 9602,
  Optional[String[16]]             $cmis_raft_secret   = undef,
  Optional[String[16]]             $cmis_api_secret    = undef,
  String[1]                        $cmis_raft_listen   = '0.0.0.0',
  Optional[Integer[100, 60000]]    $cmis_raft_heartbeat_ms   = undef,
  Optional[Integer[1]]             $cmis_raft_election_min_ms = undef,
  Optional[Integer[1, 300000]]     $cmis_raft_election_max_ms = undef,
  Boolean                          $cmis_raft_allow_aggressive_timeouts = false,
  Boolean                          $cmis_peer_tls      = true,
  Optional[Stdlib::Absolutepath]   $cmis_peer_tls_cert = undef,
  Optional[Stdlib::Absolutepath]   $cmis_peer_tls_key  = undef,
  Boolean                          $cmis_peer_ca_manage = true,
  Optional[String[1]]              $cmis_peer_ca_cert  = undef,
  Optional[String[1]]              $cmis_peer_ca_key   = undef,
  Integer[1]                       $cmis_peer_ca_days  = 3650,
  Array[String[1]]                 $cmis_peer_cert_san = [],
  Boolean                          $cmis_tls_enable    = true,
  Optional[String[1]]              $cmis_tls_cert      = undef,
  Optional[String[1]]              $cmis_tls_key       = undef,
  Boolean                          $cmis_tls_manage_cert = true,
  Optional[String[1]]              $cmis_tls_cert_cn   = undef,
  Integer[1]                       $cmis_tls_cert_days = 3650,
  Boolean                          $mia_enable         = false,
  Stdlib::Absolutepath             $mia_tpm_device     = '/dev/tpmrm0',
  Boolean                          $mia_skip_hardening = true,
  Hash[String[1], String]          $extra_env          = {},
) {
  # --- Resolve the effective container runtime ------------------------------
  $_runtime = $runtime ? {
    'auto'  => $facts['ferrogate_container_runtime'],
    default => $runtime,
  }
  if !$_runtime {
    fail('ferrogate: no container runtime found; install podman or docker, or set $runtime explicitly.')
  }

  # --- Validate the CMIS TLS configuration ----------------------------------
  if $cmis_enable and $cmis_tls_enable {
    if ($cmis_tls_cert and !$cmis_tls_key) or ($cmis_tls_key and !$cmis_tls_cert) {
      fail('ferrogate: set both cmis_tls_cert and cmis_tls_key together, or neither.')
    }
    if !$cmis_tls_cert and !$cmis_tls_key and !$cmis_tls_manage_cert {
      fail('ferrogate: cmis_tls_enable is true but no certificate was supplied and cmis_tls_manage_cert is false.')
    }
  }

  # --- Validate the CMIS HA (Raft cluster) configuration --------------------
  # A non-empty peer set means a multi-node cluster: this node must know which
  # peer entry is itself, and the fleet-wide shared secrets are mandatory (the
  # loopback-only dev secrets the binary falls back to are single-node only).
  $_cmis_cluster_multinode = $cmis_enable and ($cmis_cluster_peers != {})
  if $_cmis_cluster_multinode {
    if !$cmis_node_id {
      fail('ferrogate: cmis_cluster_peers is set but cmis_node_id is undef; pick which peer entry is this node.')
    }
    unless $cmis_node_id in $cmis_cluster_peers {
      fail("ferrogate: cmis_node_id ${cmis_node_id} is not a key in cmis_cluster_peers.")
    }
    if !$cmis_raft_secret or !$cmis_api_secret {
      fail('ferrogate: a multi-node CMIS cluster requires both cmis_raft_secret and cmis_api_secret (shared across the fleet).')
    }
  }
  # Raft timing: mirror CMIS's own startup checks so a bad value fails the
  # catalog compile instead of crash-looping the container.
  $_raft_hb   = pick($cmis_raft_heartbeat_ms, 500)
  $_raft_emin = pick($cmis_raft_election_min_ms, 1500)
  $_raft_emax = pick($cmis_raft_election_max_ms, 3000)
  if $_raft_emin < ($_raft_hb * 3) {
    fail("ferrogate: cmis_raft_election_min_ms (effective ${_raft_emin}) must be at least 3 x cmis_raft_heartbeat_ms (effective ${_raft_hb}); raising the heartbeat means raising the election timeouts too.")
  }
  if $_raft_emax <= $_raft_emin {
    fail("ferrogate: cmis_raft_election_max_ms (effective ${_raft_emax}) must be greater than cmis_raft_election_min_ms (effective ${_raft_emin}).")
  }
  if !$cmis_raft_allow_aggressive_timeouts and ($_raft_hb < 500 or $_raft_emin < 1500) {
    fail('ferrogate: a heartbeat below 500 or an election minimum below 1500 requires cmis_raft_allow_aggressive_timeouts = true.')
  }
  # Operator-supplied inter-node TLS material is a cert+key pair or nothing.
  if ($cmis_peer_tls_cert and !$cmis_peer_tls_key) or (!$cmis_peer_tls_cert and $cmis_peer_tls_key) {
    fail('ferrogate: set both cmis_peer_tls_cert and cmis_peer_tls_key together, or neither.')
  }
  # A supplied peer CA is likewise a cert+key pair or nothing. When supplied it
  # is shared fleet-wide (every node issues its leaf from the same CA); when
  # omitted the module generates a local CA (single-node, or distribute it).
  if ($cmis_peer_ca_cert and !$cmis_peer_ca_key) or (!$cmis_peer_ca_cert and $cmis_peer_ca_key) {
    fail('ferrogate: set both cmis_peer_ca_cert and cmis_peer_ca_key together, or neither.')
  }
  # The ≥16-char minimum hiqlite requires of each secret is enforced by the
  # `String[16]` parameter type, so a too-short value fails at catalog compile.

  # Resolve the subject CN for a generated self-signed certificate. Trust is by
  # SPKI pin, so the name only matters for SNI/routing — default to the FQDN.
  if $cmis_tls_cert_cn {
    $_cmis_tls_cert_cn = $cmis_tls_cert_cn
  } elsif $facts['networking'] and $facts['networking']['fqdn'] {
    $_cmis_tls_cert_cn = $facts['networking']['fqdn']
  } else {
    $_cmis_tls_cert_cn = 'cmis.ferrogate.internal'
  }

  # --- Resolve the image reference ------------------------------------------
  if $registry and $registry != '' {
    $_image = "${registry}/${image_name}:${image_tag}"
  } else {
    $_image = "${image_name}:${image_tag}"
  }

  # --- Compute the baseapp-rooted directory layout --------------------------
  # ferrogate + optional environment-variant sub-directory.
  $_suffix = $app_environment ? {
    ''      => 'ferrogate',
    default => "ferrogate/${app_environment}",
  }
  $config_dir = "/srv/application-config/${_suffix}"
  $data_dir   = "/srv/application-data/${_suffix}"
  $logs_dir   = "/srv/application-logs/${_suffix}"
  $audit_dir  = "${data_dir}/audit"
  $raft_dir   = "${data_dir}/raft"
  $issuer_dir = "${data_dir}/issuer"
  # Admin subsystem state (secrets.key, audit-pseudonym.key). Must be persistent
  # and identical on every node of a cluster: the admin subsystem refuses to
  # start when its key files differ from the ones the cluster was set up with.
  $admin_dir  = "${data_dir}/admin"

  # Re-export the parameters as body variables so the contained sub-classes can
  # read them as `$ferrogate::_<name>` (qualified class *parameters* are not
  # always resolvable cross-class in every evaluator; body variables are).
  $_user               = $user
  $_group              = $group
  $_uid                = $uid
  $_gid                = $gid
  $_manage_user        = $manage_user
  $_manage_subids      = $manage_subids
  $_subid_start        = $subid_start
  $_subid_count        = $subid_count
  $_pod_user           = "${user}-pod"
  $_pod_group          = "${group}-pod"
  $_manage_runtime     = $manage_runtime
  $_pull_image         = $pull_image
  $_manage_selinux     = $manage_selinux
  $_selinux_relabel    = $selinux_relabel
  $_rust_log           = $rust_log
  $_cmis_enable        = $cmis_enable
  $_cmis_listen        = $cmis_listen
  # Build the CMIS_TRUST_DOMAIN env line here (not via an EPP conditional) so an
  # unset value renders to '' — leaving the var out entirely so the binary keeps
  # its built-in default. MUST stay constant for a given issuer seed: the kid
  # resolves the key, the trust domain scopes it.
  if $cmis_trust_domain =~ Undef {
    $_cmis_trust_domain_line = ''
  } else {
    $_cmis_trust_domain_line = "# SPIFFE trust domain stamped into issued SVIDs / allowlists.\nCMIS_TRUST_DOMAIN=${cmis_trust_domain}"
  }
  $_cmis_port          = $cmis_port
  $_cmis_container_port = $cmis_container_port
  $_cmis_allowlist_proposals = $cmis_allowlist_proposals
  # Signature lifetimes (CMIS ≥ 0.19.12). Pre-render the env lines here (not via
  # an EPP conditional) so an unset value renders to '' — leaving the var out so
  # the binary keeps its default (SVID 30 d, allowlist 96 h). Both default unset.
  if $cmis_svid_ttl_secs =~ Undef and $cmis_allowlist_ttl_secs =~ Undef {
    $_cmis_ttl_env = ''
  } else {
    $_cmis_svid_ttl_line = $cmis_svid_ttl_secs ? {
      undef   => [],
      default => ["CMIS_SVID_TTL_SECS=${cmis_svid_ttl_secs}"],
    }
    $_cmis_allowlist_ttl_line = $cmis_allowlist_ttl_secs ? {
      undef   => [],
      default => ["CMIS_ALLOWLIST_TTL_SECS=${cmis_allowlist_ttl_secs}"],
    }
    $_cmis_ttl_env = (
      ['# Signature lifetimes (seconds): SVID + caller-allowlist validity windows.']
      + $_cmis_svid_ttl_line
      + $_cmis_allowlist_ttl_line
    ).join("\n")
  }
  # Admin subsystem env lines (pepper / password blocklist). Unset ⇒ '' so the
  # vars are left out and CMIS keeps its defaults.
  $_cmis_admin_pepper_line = $cmis_admin_pepper_file ? {
    undef   => [],
    default => ["CMIS_ADMIN_PEPPER_FILE=${cmis_admin_pepper_file}"],
  }
  $_cmis_admin_blocklist_line = $cmis_admin_password_blocklist_file ? {
    undef   => [],
    default => ["CMIS_ADMIN_PASSWORD_BLOCKLIST_FILE=${cmis_admin_password_blocklist_file}"],
  }
  $_cmis_admin_listen_line = $cmis_admin_listen ? {
    undef   => [],
    default => ["CMIS_ADMIN_LISTEN=${cmis_admin_listen}"],
  }
  $_cmis_admin_env = (
    $_cmis_admin_pepper_line + $_cmis_admin_blocklist_line + $_cmis_admin_listen_line
  ).join("\n")
  $_cmis_admin_listen = $cmis_admin_listen
  $_cmis_admin_port   = $cmis_admin_port
  # CMIS HA: render the peer set as CMIS_CLUSTER_PEERS' `id=raft,api;...` form.
  # Iterate the sorted key array (not a two-arg hash lambda) for a deterministic
  # spec the test evaluator can render. Empty hash ⇒ '' ⇒ single-node cluster.
  $_cmis_cluster_peers_spec = $cmis_cluster_peers.keys.sort.map |$id| {
    $_peer = $cmis_cluster_peers[$id]
    "${id}=${_peer['raft_addr']},${_peer['api_addr']}"
  }.join(';')
  $_cmis_node_id         = $cmis_node_id
  $_cmis_raft_port       = $cmis_raft_port
  $_cmis_api_port        = $cmis_api_port
  $_cmis_raft_addr       = "127.0.0.1:${cmis_raft_port}"
  $_cmis_api_addr        = "127.0.0.1:${cmis_api_port}"
  $_cmis_raft_secret     = $cmis_raft_secret
  $_cmis_api_secret      = $cmis_api_secret
  # Pre-render the HA env lines here, with a reliable Puppet `if`, and hand the
  # template a single ready-made string. The test evaluator mis-binds EPP
  # parameters once a template carries several typed params plus branches, so we
  # keep the cmis.env template branch-free and small.
  if $_cmis_cluster_multinode {
    # CMIS_RAFT_LISTEN binds the routable interface (peers reach this node here);
    # the advertised addr each peer dials is still its cmis_cluster_peers entry.
    $_cmis_ha_base = [
      '# CMIS High Availability (F05): multi-node hiqlite Raft cluster.',
      '# Peers: id=raft_addr,api_addr entries joined by ; (this node included).',
      "CMIS_CLUSTER_PEERS=${_cmis_cluster_peers_spec}",
      "CMIS_NODE_ID=${cmis_node_id}",
      "CMIS_RAFT_LISTEN=${cmis_raft_listen}",
    ]
  } else {
    $_cmis_ha_base = [
      '# CMIS High Availability (F05): single-node cluster (loopback transports).',
      "CMIS_RAFT_ADDR=${_cmis_raft_addr}",
      "CMIS_API_ADDR=${_cmis_api_addr}",
    ]
  }
  # --- Managed inter-node (peer) transport CA + leaf ------------------------
  # hiqlite's split-brain / metrics client validates the peer cert with rustls'
  # platform verifier (the OS trust store *inside the container*), not the
  # shared-secret handshake — so a bare self-signed CMIS_PEER_TLS=1 cert fails
  # with `UnknownIssuer`. Instead issue this node's leaf from a CA (supplied
  # fleet-wide via cmis_peer_ca_cert/_key, else generated locally) and point the
  # container's verifier at that CA through SSL_CERT_FILE. Active only for a
  # multi-node cluster that wants peer TLS and did not supply its own leaf pair.
  $_peer_ca_active = $_cmis_cluster_multinode and $cmis_peer_tls and $cmis_peer_ca_manage and !($cmis_peer_tls_cert and $cmis_peer_tls_key)
  $_cmis_peer_tls        = $cmis_peer_tls
  $_cmis_peer_tls_cert   = $cmis_peer_tls_cert
  $_cmis_peer_tls_key    = $cmis_peer_tls_key
  $_cmis_peer_ca_cert    = $cmis_peer_ca_cert
  $_cmis_peer_ca_key     = $cmis_peer_ca_key
  $_cmis_peer_ca_days    = $cmis_peer_ca_days
  # The CA cert + this node's leaf live in a dir bind-mounted into the CMIS
  # container; the CA *private* key (and the CSR/serial scratch files) stay
  # host-only under the config root and are never mounted.
  $_peer_tls_dir            = "${config_dir}/peer-tls"
  $_peer_ca_cert_file       = "${config_dir}/peer-tls/ca.crt"
  $_peer_cert_file          = "${config_dir}/peer-tls/peer.crt"
  $_peer_key_file           = "${config_dir}/peer-tls/peer.key"
  $_peer_ca_key_file        = "${config_dir}/peer-ca.key"
  $_peer_csr_file           = "${config_dir}/peer-ca.csr"
  $_peer_serial_file        = "${config_dir}/peer-ca.srl"
  $_peer_tls_container_dir  = '/etc/ferrogate/peer-tls'
  $_peer_tls_container_ca   = '/etc/ferrogate/peer-tls/ca.crt'
  $_peer_tls_container_cert = '/etc/ferrogate/peer-tls/peer.crt'
  $_peer_tls_container_key  = '/etc/ferrogate/peer-tls/peer.key'
  # Leaf subject + SANs. rustls checks the advertised name peers dial against the
  # leaf SAN, so it must be present. Default to the node FQDN (the same name the
  # CMIS listener CN resolves to); operators add IPs/extra hostnames via
  # cmis_peer_cert_san (each a raw openssl SAN entry, e.g. 'IP:10.0.0.2').
  $_peer_ca_cn   = 'FerroGate CMIS Peer CA'
  $_peer_cert_cn = $_cmis_tls_cert_cn
  $_peer_san     = (["DNS:${_cmis_tls_cert_cn}"] + $cmis_peer_cert_san).join(',')
  if $cmis_raft_secret {
    $_raft_secret_lines = ["CMIS_RAFT_SECRET=${cmis_raft_secret}"]
  } else {
    $_raft_secret_lines = []
  }
  if $cmis_api_secret {
    $_api_secret_lines = ["CMIS_API_SECRET=${cmis_api_secret}"]
  } else {
    $_api_secret_lines = []
  }
  # Inter-node transport TLS (multi-node only). An operator cert+key pair takes
  # precedence over the self-signed switch; the binary reads cert/key first and
  # falls back to CMIS_PEER_TLS=1. Peer identity is authenticated by the shared
  # secret, so TLS here is for on-the-wire confidentiality.
  if !$_cmis_cluster_multinode {
    $_cmis_peer_tls_lines = []
  } elsif $cmis_peer_tls_cert and $cmis_peer_tls_key {
    $_cmis_peer_tls_lines = [
      "CMIS_PEER_TLS_CERT=${cmis_peer_tls_cert}",
      "CMIS_PEER_TLS_KEY=${cmis_peer_tls_key}",
    ]
  } elsif $_peer_ca_active {
    # Module-issued leaf from a (supplied or generated) CA. SSL_CERT_FILE makes
    # the container's rustls platform verifier trust that CA, so the split-brain
    # / metrics client accepts peer leaves issued from it (ferrogate::peer_ca).
    $_cmis_peer_tls_lines = [
      "CMIS_PEER_TLS_CERT=${_peer_tls_container_cert}",
      "CMIS_PEER_TLS_KEY=${_peer_tls_container_key}",
      "SSL_CERT_FILE=${_peer_tls_container_ca}",
    ]
  } elsif $cmis_peer_tls {
    $_cmis_peer_tls_lines = ['CMIS_PEER_TLS=1']
  } else {
    $_cmis_peer_tls_lines = []
  }
  # Raft timing overrides (multi-node only); unset parameters render nothing.
  if $_cmis_cluster_multinode {
    $_cmis_raft_timing_lines = [
      $cmis_raft_heartbeat_ms ? { undef => [], default => ["CMIS_RAFT_HEARTBEAT_MS=${cmis_raft_heartbeat_ms}"] },
      $cmis_raft_election_min_ms ? { undef => [], default => ["CMIS_RAFT_ELECTION_MIN_MS=${cmis_raft_election_min_ms}"] },
      $cmis_raft_election_max_ms ? { undef => [], default => ["CMIS_RAFT_ELECTION_MAX_MS=${cmis_raft_election_max_ms}"] },
      $cmis_raft_allow_aggressive_timeouts ? { true => ['CMIS_RAFT_ALLOW_AGGRESSIVE_TIMEOUTS=true'], default => [] },
    ].flatten
  } else {
    $_cmis_raft_timing_lines = []
  }
  $_cmis_ha_env = ($_cmis_ha_base + $_raft_secret_lines + $_api_secret_lines + $_cmis_peer_tls_lines + $_cmis_raft_timing_lines).join("\n")
  $_cmis_tls_enable      = $cmis_tls_enable
  $_cmis_tls_cert        = $cmis_tls_cert
  $_cmis_tls_key         = $cmis_tls_key
  $_cmis_tls_manage_cert = $cmis_tls_manage_cert
  $_cmis_tls_cert_days   = $cmis_tls_cert_days
  # On-disk (host) and in-container paths for the TLS material. The cert/key
  # directory is bind-mounted into the CMIS container; the SPKI pin file is a
  # host-only convenience kept under the login-user-owned config root so
  # operators (and root) can read it to configure MIA pinning.
  $_tls_dir            = "${config_dir}/tls"
  $_tls_cert_file      = "${config_dir}/tls/cmis.crt"
  $_tls_key_file       = "${config_dir}/tls/cmis.key"
  $_tls_pin_file       = "${config_dir}/cmis.spki-pin.txt"
  $_tls_container_dir  = '/etc/ferrogate/tls'
  $_tls_container_cert = '/etc/ferrogate/tls/cmis.crt'
  $_tls_container_key  = '/etc/ferrogate/tls/cmis.key'
  $_mia_enable         = $mia_enable
  $_mia_tpm_device     = $mia_tpm_device
  $_mia_skip_hardening = $mia_skip_hardening
  $_extra_env          = $extra_env

  # The shared /srv/application-* roots stay root:root 0755 (baseapp defaults)
  # so every app user on the node can traverse to its own subdirectory. The
  # FerroGate-owned tree lives in the per-app subdirs that ferrogate::config
  # creates ($user-owned, 0750). Overriding the roots to ferrogate:ferrogate
  # 0750 here locked other apps (e.g. bastionvault) out of their own subdirs,
  # since the roots then had no traverse bit for "other".
  include baseapp

  class { 'ferrogate::install': }
  class { 'ferrogate::config': }
  class { 'ferrogate::selinux': }
  class { 'ferrogate::service': }

  contain baseapp
  contain ferrogate::install
  contain ferrogate::config
  contain ferrogate::selinux
  contain ferrogate::service

  # CMIS TLS material (cert/key placement or generation, plus the SPKI pin).
  # Only relevant when CMIS terminates TLS on this node.
  if $cmis_enable and $cmis_tls_enable {
    class { 'ferrogate::tls': }
    contain ferrogate::tls
  }

  # Inter-node (peer) transport CA + this node's leaf, when the managed-CA path
  # is active (multi-node, peer TLS on, no operator-supplied leaf).
  if $_peer_ca_active {
    class { 'ferrogate::peer_ca': }
    contain ferrogate::peer_ca
  }

  # Host-side operator CLI wrapper. Only useful when CMIS is running, since the
  # `ferrogate` CLI is a gRPC client of CMIS. The wrapper is a static host script
  # whose write does not require the container to be running, so order it after
  # `install` (which creates the service user the wrapper sudo's to) rather than
  # after the whole `service` class — a container-start failure (e.g. an
  # unsupported MIA image) must not skip the wrapper and its sudoers drop-in.
  # Declared as a `require` metaparameter (not a `->` chain) so the ordering edge
  # is materialized in the catalog for both real applies and the test evaluator.
  if $cmis_enable {
    class { 'ferrogate::cli':
      require => Class['ferrogate::install'],
    }
    contain ferrogate::cli
  }

  # baseapp now owns the shared /srv roots as root:root and no longer depends
  # on the ferrogate user, so it can run first. ferrogate::config creates the
  # per-app subdirs beneath those roots, so it must come after both baseapp
  # (roots exist) and install (ferrogate user exists).
  Class['baseapp']
  -> Class['ferrogate::install']
  -> Class['ferrogate::config']
  -> Class['ferrogate::selinux']
  -> Class['ferrogate::service']

  # The CMIS instance bind-mounts the TLS directory, so the cert/key must be in
  # place before the service starts. Slot the tls class between config (which
  # creates the config root it writes into) and service.
  if $cmis_enable and $cmis_tls_enable {
    Class['ferrogate::config']
    -> Class['ferrogate::tls']
    -> Class['ferrogate::service']
  }

  # The peer-CA material is likewise bind-mounted into the CMIS container, so it
  # must exist before the service starts. Slot it between config and service.
  if $_peer_ca_active {
    Class['ferrogate::config']
    -> Class['ferrogate::peer_ca']
    -> Class['ferrogate::service']
  }

}
