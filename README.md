# Prometheus AlertManager to LogicMonitor (LM Logs)

Kubernetes manifests and documentation for forwarding Prometheus AlertManager alerts into LogicMonitor as structured webhook logs.

## Architecture

```
+-----------------+     +------------------+     +-------------------+
| PrometheusRule  | --> | AlertManager     | --> | LM Webhook        |
| (fires alert)   |     | (routes by       |     | LogSource         |
|                 |     |  severity/ns)    |     | (parses + maps)   |
+-----------------+     +------------------+     +-------------------+
                                                         |
                                                         v
                                                 +-------------------+
                                                 | LM Logs           |
                                                 | (query, alert,    |
                                                 |  dashboard)       |
                                                 +-------------------+
```

**Data flow:**
1. Prometheus evaluates alerting rules defined in PrometheusRules
2. AlertManager receives alerts and routes based on labels (namespace, severity)
3. AlertManager POSTs JSON payload to LogicMonitor webhook endpoint
4. LogicMonitor LogSource parses payload and extracts structured fields
5. Resource mapping correlates logs to monitored Kubernetes cluster resources
6. LogAlerts evaluate log patterns and generate LogicMonitor alerts

## Prerequisites

| Requirement | Details |
|---|---|
| OpenShift Version | 4.12+ (ARO, ROSA, or self-managed) |
| User Workload Monitoring | Enabled on cluster |
| Permissions | cluster-admin or monitoring-edit role |
| Network Egress | HTTPS (443) to `*.logicmonitor.com` |
| LM Logs | Enabled on your LogicMonitor portal |
| LM API User | Bearer token with `lm_logs_administrator` role |

### Enable User Workload Monitoring

Two ConfigMaps are required.

**Step 1: Enable user workload monitoring** (in `openshift-monitoring`):

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

**Step 2: Enable AlertManager and AlertmanagerConfig reconciliation** (in `openshift-user-workload-monitoring`):

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: user-workload-monitoring-config
  namespace: openshift-user-workload-monitoring
data:
  config.yaml: |
    alertmanager:
      enabled: true
      enableAlertmanagerConfig: true
```

Both `enabled` and `enableAlertmanagerConfig` are required. Without `enableAlertmanagerConfig`, the operator ignores AlertmanagerConfig CRDs.

Verify AlertManager pods are running:

```bash
oc get pods -n openshift-user-workload-monitoring -l app.kubernetes.io/name=alertmanager
```

## Quick Start

### 1. Prepare Your Namespace

Label the target namespace for user workload monitoring:

```bash
oc label namespace <namespace> \
  openshift.io/cluster-monitoring=false \
  openshift.io/user-monitoring=true \
  --overwrite
```

### 2. Configure the Overlay

Edit the overlay for your cluster in `manifests/overlays/<cluster>/kustomization.yaml`:

- Set `namespace:` to your target namespace
- Replace `PORTAL_NAME` in the webhook URL with your LM portal name
- Replace `REPLACE_WITH_BEARER_TOKEN` with your LM Bearer token

### 3. Deploy

```bash
oc apply -k manifests/overlays/<cluster>/
```

### 4. Verify

List deployed AlertmanagerConfigs:

```bash
oc get alertmanagerconfig -A -l openshift.io/user-monitoring=true
```

Verify the generated AlertManager configuration:

```bash
oc get secret alertmanager-user-workload-generated \
  -n openshift-user-workload-monitoring \
  -o jsonpath='{.data.alertmanager\.yaml\.gz}' | base64 -d | gunzip
```

### 5. Test

**Option A: Direct webhook test (bypasses AlertManager)**

```bash
./manifests/test/test-webhook-curl.sh <portal_name> <bearer_token> <cluster_name>
```

**Option B: End-to-end test via PrometheusRule**

Edit `manifests/test/test-prometheus-rule.yaml`:
- Replace `REPLACE_WITH_NAMESPACE` with your target namespace
- Replace `REPLACE_WITH_CLUSTER_NAME` with your cluster name

```bash
oc apply -f manifests/test/test-prometheus-rule.yaml -n <namespace>
```

The test alert fires after 1 minute. Verify in LM Logs:

```
source_type="prometheus_alertmanager" AND alertname="LogicMonitorWebhookTest"
```

Delete the test rule when done:

```bash
oc delete -f manifests/test/test-prometheus-rule.yaml -n <namespace>
```

## LogicMonitor Portal Configuration

### LogSource

A webhook LogSource named `OpenShift_AlertManager_Webhook` must exist on your portal. It extracts these fields from the AlertManager JSON payload:

| Field | Extraction Method | Value |
|---|---|---|
| status | WebhookAttribute | status |
| alertname | Regex | `"alertname":"([^"]+)"` |
| namespace | Regex | `"namespace":"([^"]+)"` |
| severity | Regex | `"severity":"([^"]+)"` |
| cluster_name | Regex | `"cluster_name":"([^"]+)"` |
| receiver | WebhookAttribute | receiver |
| instance | Regex | `"instance":"([^"]+)"` |
| source_type | Static | prometheus_alertmanager |

### Resource Mapping

The LogSource uses Dynamic Group Regex to map incoming logs to cluster resources:

| Key | Regex |
|---|---|
| `openshift.cluster.name` | `"cluster_name"\s*:\s*"([^"]+)"` |

Each monitored cluster resource must have a custom property `openshift.cluster.name` set to the cluster name used in PrometheusRule labels.

### PrometheusRule Label Requirements

Alert rules MUST include explicit labels for routing and resource mapping:

| Label | Purpose | Required |
|---|---|---|
| `namespace` | Routes alert to correct AlertmanagerConfig | Yes |
| `cluster_name` | Enables resource mapping in LogicMonitor | Yes |
| `severity` | Matches AlertmanagerConfig route matchers | Yes |

When using `leaf-prometheus` scope, the namespace label is not automatically injected. Alerts without it will not match any route.

Example:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: application-alerts
  namespace: my-namespace
  labels:
    openshift.io/prometheus-rule-evaluation-scope: leaf-prometheus
spec:
  groups:
    - name: application.alerts
      rules:
        - alert: HighErrorRate
          expr: rate(http_errors_total[5m]) > 10
          for: 5m
          labels:
            severity: warning
            namespace: my-namespace
            cluster_name: my-cluster
          annotations:
            summary: "High error rate detected"
```

## LMQL Query Reference

```
# All AlertManager logs
source_type="prometheus_alertmanager"

# Firing alerts only
source_type="prometheus_alertmanager" AND status="firing"

# Critical severity
source_type="prometheus_alertmanager" AND severity="critical"

# Specific cluster
source_type="prometheus_alertmanager" AND cluster_name="my-cluster"

# Count by severity
source_type="prometheus_alertmanager" | count by severity

# Top 10 alerts
source_type="prometheus_alertmanager" | count by alertname | sort by _count desc | limit 10
```

## Adding New Namespaces

Repeat for each namespace that needs AlertManager integration:

```bash
# 1. Label namespace
oc label namespace <new-namespace> \
  openshift.io/cluster-monitoring=false \
  openshift.io/user-monitoring=true \
  --overwrite

# 2. Deploy secret
oc create secret generic logicmonitor-bearer-token \
  --from-literal=token="<bearer-token>" \
  -n <new-namespace>

# 3. Deploy AlertmanagerConfig
oc apply -f manifests/base/alertmanager-config.yaml -n <new-namespace>

# 4. Verify
oc get alertmanagerconfig -n <new-namespace>
```

## Troubleshooting

| Symptom | Resolution |
|---|---|
| AlertmanagerConfig not applied | Verify namespace and AlertmanagerConfig both have `openshift.io/user-monitoring: "true"` label |
| Routes not in generated config | Ensure `enableAlertmanagerConfig: true` is set in `user-workload-monitoring-config` ConfigMap |
| Webhook returns 401 | Check Bearer token is correct, not expired, and has LM Logs permissions |
| Webhook returns 202 but no logs | Verify API user has `lm_logs_administrator` role, not just `manager` |
| Alerts not reaching LM | Add explicit `namespace` label to PrometheusRule alert definitions |
| Logs not mapping to resources | Add `openshift.cluster.name` property to cluster resource, verify `cluster_name` label in alerts |
| ARO egress blocked | Whitelist `*.logicmonitor.com:443` in ARO egress lockdown firewall rules |

## Bearer Token Rotation

```bash
# Update secrets in all namespaces
for ns in namespace-a namespace-b; do
  oc delete secret logicmonitor-bearer-token -n $ns --ignore-not-found
  oc create secret generic logicmonitor-bearer-token \
    --from-literal=token="<new-token>" \
    -n $ns
done

# Restart AlertManager to pick up changes
oc delete pod -n openshift-user-workload-monitoring \
  -l app.kubernetes.io/name=alertmanager
```

## Reference

- [LM Logs Webhook Events](https://www.logicmonitor.com/support/webhook-events-as-logs)
- [LogSource Configuration](https://www.logicmonitor.com/support/logsource-configuration)
- [LMQL Reference](https://www.logicmonitor.com/support/logicmonitor-query-language-reference)
- [OpenShift User Workload Monitoring](https://docs.redhat.com/en/documentation/openshift_container_platform/4.16/html/monitoring/enabling-monitoring-for-user-defined-projects)
- [AlertmanagerConfig CRD](https://docs.redhat.com/en/documentation/openshift_container_platform/4.16/html/monitoring_apis/alertmanagerconfig-monitoring-coreos-com-v1beta1)
