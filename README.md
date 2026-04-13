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
5. Resource mapping stores cluster and alert attributes on log entries
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

**Step 2: Enable AlertManager, AlertmanagerConfig, and external labels** (in `openshift-user-workload-monitoring`):

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
    prometheus:
      externalLabels:
        cluster_name: <your-cluster-name>
```

Both `enabled` and `enableAlertmanagerConfig` are required. Without `enableAlertmanagerConfig`, the operator ignores AlertmanagerConfig CRDs. The `cluster_name` external label is injected into all alerts for resource mapping in LogicMonitor.

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
_lm.logsource_name = "OpenShift_AlertManager_Webhook"
```

Delete the test rule when done:

```bash
oc delete -f manifests/test/test-prometheus-rule.yaml -n <namespace>
```

## LogicMonitor Portal Configuration

### LogSource

Import the LogSource definition from `logsource/OpenShift_AlertManager_Webhook.json` via the LM REST API:

```bash
curl -X POST "https://<portal>.logicmonitor.com/santaba/rest/setting/logsources" \
  -H "Authorization: Bearer <your-token>" \
  -H "Content-Type: application/json" \
  -d @logsource/OpenShift_AlertManager_Webhook.json
```

Or create it manually in the portal (Settings > LM Logs > Log Sources > Add). The LogSource uses two extraction methods: WebhookAttribute (JSONPath for structured access) and RegexGroup (regex fallback on the raw payload body). Both are recommended for reliability.

| Field | Method | Value |
|---|---|---|
| status | WebhookAttribute | `$.status` |
| receiver | WebhookAttribute | `$.receiver` |
| alertname | WebhookAttribute | `$.alerts[*].labels.alertname` |
| namespace | WebhookAttribute | `$.alerts[*].labels.namespace` |
| severity | WebhookAttribute | `$.alerts[*].labels.severity` |
| summary | WebhookAttribute | `$.alerts[*].annotations.summary` |
| nodename | WebhookAttribute | `$.alerts[*].labels.instance_name` |
| a_alertname | RegexGroup | `"alertname"\s*:\s*"([^"]+)"` |
| a_severity | RegexGroup | `"severity"\s*:\s*"([^"]+)"` |
| a_summary | RegexGroup | `"summary"\s*:\s*"([^"]+)"` |
| a_description | RegexGroup | `"description"\s*:\s*"((?:[^"\\\\]|\\\\.)*)"` |
| a_pod | RegexGroup | `"pod"\s*:\s*"([^"]+)"` |
| a_nodename | RegexGroup | `"instance_name"\s*:\s*"([^"]+)"` |
| a_genURL | RegexGroup | `"generatorURL"\s*:\s*"((?:[^"\\\\]|\\\\.)*)"` |

### Resource Mapping

The LogSource uses RegexGroup to extract attributes stored on each log entry in `_resource.attributes`. These are metadata fields for querying and identification, not device associations (webhook-based logs do not populate the Resource or Resource Type columns in LM Logs -- that is a platform limitation for webhook ingestion).

| Key | Regex | Purpose |
|---|---|---|
| `openshift.instance.name` | `"instance_name"\s*:\s*"([^"]+)"` | Cluster or node instance name |
| `openshift.alert.name` | `"alertname"\s*:\s*"([^"]+)"` | Alert name for filtering |
| `openshift.cluster.name` | `"cluster_name"\s*:\s*"([^"]+)"` | Cluster name for identification |

### Cluster Name for Resource Mapping

The LogSource resource mapping extracts `cluster_name` from alert labels to associate logs with the correct cluster device. There are two ways to provide this:

**Option A: Prometheus external labels (recommended)**

Add `cluster_name` as an external label in `user-workload-monitoring-config`. This automatically injects the label into all alerts without modifying individual PrometheusRules:

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
    prometheus:
      externalLabels:
        cluster_name: my-cluster
```

**Option B: Per-rule labels**

Add `cluster_name` directly in PrometheusRule label definitions. Use this when external labels cannot be set.

### PrometheusRule Label Requirements

| Label | Purpose | Required |
|---|---|---|
| `namespace` | Routes alert to correct AlertmanagerConfig | Yes |
| `cluster_name` | Enables resource mapping in LogicMonitor | Yes (via external labels or per-rule) |
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
            cluster_name: my-cluster  # not needed if using external labels
          annotations:
            summary: "High error rate detected"
```

## LMQL Query Reference

```
# All AlertManager webhook logs
_lm.logsource_name = "OpenShift_AlertManager_Webhook"

# Firing alerts only
_lm.logsource_name = "OpenShift_AlertManager_Webhook" AND a_severity = "critical"

# Specific alert name
_lm.logsource_name = "OpenShift_AlertManager_Webhook" AND a_alertname = "HighErrorRate"

# Specific cluster (requires cluster_name label in alerts)
_lm.logsource_name = "OpenShift_AlertManager_Webhook" AND a_nodename = "my-cluster"

# Search within alert descriptions
_lm.logsource_name = "OpenShift_AlertManager_Webhook" AND "backup failed"
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
| Webhook returns 202 but no logs | Verify API user has `lm_logs_administrator` role. Check LogSource uses JSONPath for WebhookAttribute values (e.g., `$.status` not `status`). Remove SourceName filters unless verified working. |
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
