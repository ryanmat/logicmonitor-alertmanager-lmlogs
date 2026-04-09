# ARO-Specific Considerations

Azure Red Hat OpenShift (ARO) has specific behaviors that affect this integration.

## Egress Lockdown

ARO has egress lockdown enabled by default on new clusters. This proxies outbound connections through the ARO management infrastructure and restricts traffic to whitelisted domains.

The AlertManager webhook needs outbound HTTPS to your LogicMonitor portal. If egress lockdown is active, whitelist `*.logicmonitor.com` on port 443 in your ARO firewall rules.

Reference: [ARO Egress Lockdown](https://learn.microsoft.com/en-us/azure/openshift/concepts-egress-lockdown)

## Platform Monitoring Namespace

The `openshift-monitoring` namespace is managed by Microsoft and Red Hat SRE. You cannot:

- Modify the platform AlertManager configuration
- Add custom receivers to the platform AlertManager
- Change default alert routing for platform alerts

All custom webhook routing must use user workload monitoring (`openshift-user-workload-monitoring`).

## Receiving Platform-Level Alerts

To receive platform-level alerts (node conditions, etcd health, API server issues) in LogicMonitor:

1. Create a dedicated namespace (e.g., `platform-alerts`) with user workload monitoring labels
2. Deploy PrometheusRules in that namespace that query kube-state-metrics for infrastructure conditions
3. Route through the user workload AlertManager using the standard AlertmanagerConfig webhook

This replicates the platform signals through user workload monitoring without modifying the managed platform stack.

## Supported Versions

ARO currently ships OpenShift 4.15, 4.16, 4.18, and 4.19. All versions support:

- User workload monitoring via `cluster-monitoring-config` ConfigMap
- AlertmanagerConfig CRD (`monitoring.coreos.com/v1beta1`)
- Webhook receivers in user workload AlertManager

## User Workload Monitoring

The enablement process is identical to standard OpenShift:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
```

Monitoring for user-defined projects is disabled by default on ARO.
