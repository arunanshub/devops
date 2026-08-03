# Cilium 1.20 Helm values: full decision matrix

## Scope

This reviews all **174 top-level values** in the exact
`quay.io/cilium/charts/cilium:1.20.0` schema, not merely the values overridden
in Git. It compares those areas with `kubernetes/base/infra/cilium/values.yaml`
and the live agent state reviewed in the accompanying networking audit. Leaf
values inherit the chart default unless explicitly set. "Do not use" means
not useful in this single-cluster, three-control-plane, Hetzner-L3, VXLAN +
WireGuard design; it does not mean the feature is universally inappropriate.

The source reference is [Cilium's Helm reference](https://docs.cilium.io/en/stable/helm-reference/).

## Material decisions

| Decision | Why |
| --- | --- |
| Keep KPR, Kubernetes IPAM, VXLAN, BPF masquerade, BBR, and PMTU discovery | They match K3s without kube-proxy, Hetzner's L3 network, and the measured MTU/map state. |
| Keep WireGuard strict pod-CIDR encryption | Cross-node pod traffic is encrypted. Control-plane node-encryption opt-out is expected and affects the optional node/host extension, not pod-to-pod encryption. |
| Disable standalone Envoy in desired state | The required gate passed: three live Envoy pods have no L7 policy, Cilium Gateway/Ingress, CiliumEnvoyConfig, or DNS/FQDN-policy consumer. |
| Do not add native routing, netkit, BIG TCP, BGP, L2, DSR/XDP/Maglev, or egress gateway | Each assumes another network model or an unobserved scale/load trigger. None is a proven safe improvement here. |
| Keep observability, policy enforcement, health checks, RBAC/probes, and ConfigMap drift detection | Their modest cost produces current incident evidence and avoids silent configuration regression. |

## Functional-area coverage

| Chart values | Decision | Why / why not |
| --- | --- | --- |
| `kubeProxyReplacement`, `k8sServiceHost`, `k8sServicePort`, `k8sServiceHostRef`, `k8sServiceLookup*`, `waitForKubeProxy`, `kubeConfigPath`, `k8s` | **Keep** | K3s kube-proxy is intentionally disabled. The stable private API LB prevents an agent bootstrap dependency on Service lookup. |
| `ipam`, `eni`, `azure`, `alibabacloud`, `aksbyocni`, `gke`, `nodeIPAM`, `ipv4`, `ipv6`, `preferIpv6`, `*NativeRoutingCIDR` | **Kubernetes IPAM only** | K3s allocates pod CIDRs; this is neither an ENI nor a managed-cloud CNI environment. IPv4-only is deliberate. |
| `routingMode`, `tunnelProtocol`, `tunnelPort`, `tunnelSourcePortRange`, `underlayProtocol`, `autoDirectNodeRoutes`, `directRoutingSkipUnreachable`, `devices`, `forceDeviceDetection`, `MTU`, `vtep` | **Keep VXLAN/auto-MTU** | Hetzner Networks are L3. Native routing requires maintained pod-CIDR routes through node gateways; VTEP has no peer. |
| `encryption`, `authentication`, `tls`, `wellKnownIdentities` | **Keep WireGuard** | It meets the actual cross-node-pod requirement with less machinery. Do not add IPsec/SPIRE-style mutual authentication without a workload need; mutual auth is deprecated. |
| `bpf`, `bpfClockProbe`, `datapathPlugins`, `endpointRoutes`, `installNoConntrackIptablesRules`, `iptablesRandomFully`, `enableXTSocketFallback`, `enable*Masquerade*`, `nat`, `nat46x64Gateway`, `ipMasqAgent` | **Keep BPF defaults** | BPF masquerade/KPR are correct. Low map pressure does not justify distributed LRU or preallocation. NAT46/IPv6 have no consumer. |
| `bandwidthManager`, `pmtuDiscovery`, `conntrackGC*`, `connectivityProbeFrequencyRatio`, `enable*BIGTCP` | **Keep BBR/PMTU; no tuning/BIG TCP** | BBR helps egress. BIG TCP requires native, unencrypted/non-tunnel networking and supported NICs, which conflicts with VXLAN + WireGuard. |
| `socketLB`, `loadBalancer`, `nodePort`, `maglev`, `serviceNoBackendResponse`, `enableNoServiceEndpointsRoutable`, `enableInternalTrafficPolicy`, `enableLBIPAM`, `defaultLBServiceIPAM`, `l2NeighDiscovery` | **Leave defaults** | No NodePort/LB data path exists; cloudflared uses ClusterIP. Socket LB is off; do not enable it to support Traefik. LB-IPAM is dormant without a pool. `defaultLBServiceIPAM: none` is only future policy clarity. |
| `l2announcements`, `l2podAnnouncements`, `bgpControlPlane`, `egressGateway`, `localRedirectPolicies`, `localRedirectPolicy` | **Do not use** | They add L2/BGP/egress-route control planes or special Service behaviour with no network peer/use case. |
| `gatewayAPI`, `ingressController`, `envoy`, `envoyConfig`, `l7Proxy`, `standaloneDnsProxy`, `dnsProxy`, `dnsPolicy`, `sctp` | **Traefik owns Gateway; Envoy disabled** | Cilium Gateway/Ingress duplicates Traefik. The L7/DNS/FQDN gate passed, so desired state disables standalone Envoy. Do not enable SCTP/DNS standalone functions without workloads. |
| `policyEnforcementMode`, `policyCIDRMatchMode`, `policyDenyResponse`, `policyAuditMode`, `k8sNetworkPolicy`, `k8sClusterNetworkPolicy`, `enableNonDefaultDenyPolicies`, `hostFirewall`, `endpointLockdownOnMapOverflow`, `endpointPolicyUpdateTimeoutDuration` | **Keep enforced policy; separately design host firewall** | Audit-only weakens current controls. Host firewall could protect node listeners but needs inventory, audit mode and serial rollout; it is not a one-flag optimization. |
| `hubble`, `monitor`, `prometheus`, `dashboards`, `certgen`, `healthChecking`, `endpointHealthChecking`, `healthPort`, `healthCheckICMPFailureThreshold` | **Keep** | Hubble ring turnover is bounded history, not datapath loss. Metrics/health endpoints provide cheap operational evidence. |
| `ciliumEndpointSlice`, `identityAllocationMode`, `identityManagementMode`, `identityChangeGracePeriod`, `disableEndpointCRD`, `synchronizeK8sNodes`, `annotateK8sNode`, `agentNotReadyTaintKey` | **Leave defaults** | No endpoint or identity scale pressure exists. These alter reconciliation semantics rather than solving a measured throughput problem. |
| `cgroup`, `sysctlfix`, `nodeinit`, `cleanBpfState`, `cleanState`, `preflight`, `cni`, `daemon` | **Keep host cgroup; lifecycle controls only when needed** | The host cgroup works. Node init/sysctl fix adds privileged host mutation. Cleanup and preflight are recovery/upgrade controls, not normal configuration. |
| `apiRateLimit`, `k8sClientRateLimit`, `k8sClientExponentialBackoff`, `crdWaitTimeout`, `configDriftDetection`, `debug`, `pprof`, `logSystemLoad` | **Keep drift detection; default rates/debug** | No API throttle/reconciliation fault supports QPS/backoff changes. Debug and pprof should be incident-scoped. |
| `operator`, `etcd`, `clustermesh`, `resourceQuotas`, `enableCriticalPriorityClass` | **Keep two operators; no etcd/clustermesh** | Operator HA matters. External Cilium etcd/ClusterMesh add state and peering with no multi-cluster need. |
| `resources`, `initResources`, `image`, `imagePullSecrets`, `serviceAccounts`, `rbac`, `securityContext`, `podSecurityContext`, `priorityClassName`, `nodeSelector`, `nodeSelectorLabels`, `affinity`, `tolerations`, `scheduling`, `updateStrategy`, `minReadySeconds`, `terminationGracePeriodSeconds`, `rollOutCiliumPods` | **Keep; do not tune blind** | Current agent resource use is low. Security/RBAC should remain chart-managed. Rollout knobs protect availability, not steady-state performance. |
| `readinessProbe`, `livenessProbe`, `startupProbe`, `keepDeprecatedLabels`, `keepDeprecatedProbes`, `upgradeCompatibility` | **Keep defaults** | These are compatibility and upgrade-risk controls; change only along the chart's documented upgrade path. |
| `namespaceOverride`, `name`, `commonLabels`, `annotations`, `podAnnotations`, `podLabels`, `secretsNamespace*`, `extraArgs`, `extraConfig`, `extraContainers`, `extraInitContainers`, `extraEnv`, `extraHostPathMounts`, `extraVolumes`, `extraVolumeMounts`, `tmpVolume`, `sleepAfterInit` | **Use only for a proved integration gap** | This is chart plumbing, not a performance feature. Preserve the existing `extraConfig` disabling Cilium Gateway ownership; other additions expand support and attack surface. |

## Explicitly rejected shortcuts

`bpf.datapathMode=netkit` is beta and cannot switch existing veth pods in
place; its documented layout also expects native routing/BPF host routing.
`distributedLRU` and map preallocation buy capacity at a memory cost that the
measured 3.5% peak map pressure does not justify.

Enabling Cilium socket LB and Traefik Service-IP routing together would be a
new combined routing experiment, not a current optimization. Traefik already
uses direct pod endpoints and reuses backend connections.

## Follow-up boundaries

1. Re-enable `envoy.enabled` before introducing a Cilium L7 policy,
   CiliumEnvoyConfig, Cilium Gateway/Ingress, DNS proxy/FQDN policy, or Cilium
   L7 visibility requirement.
2. Set `defaultLBServiceIPAM: none` only if the intended policy is to prevent
   accidental Cilium allocation when a future pool appears. It has no current
   performance effect and must retain external Hetzner CCM ownership.
3. Treat host firewall as a separate security design: inventory listeners,
   start in audit mode, and roll one node at a time.
