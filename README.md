# Prometheus AlertManager to LogicMonitor (LM Logs)

Kubernetes manifests and documentation for forwarding Prometheus AlertManager alerts into LogicMonitor as structured webhook logs.

## Architecture

```
+-----------------+     +------------------+     +-------------------+
| PrometheusRule  | --> | AlertManager     | --> | LM Webhook        |
| (fires alert)   |     | (routes by       |     | LogSource         |
|                 |     |  severity/ns)    |     | (parses + extract)|
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
4. LogicMonitor LogSource parses the payload and extracts structured fields
5. Logs are queryable in LM Logs by `sourceName`, `cluster_name`, `alertname`, and 22 other fields

**Known limitation:** webhook-based logs do NOT populate the Resource or Resource Type columns in the LM Logs UI. This is a platform behavior of webhook ingestion, not a configuration issue. For per-device log-to-alert correlation in the LM UI, use a collector-based ingestion path (Fluentd sidecar forwarding to the LM Ingest API). See `manifests/fluentd-sidecar/` for a starting point.

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

Both `enabled` and `enableAlertmanagerConfig` are required. Without `enableAlertmanagerConfig`, the operator ignores AlertmanagerConfig CRDs. The `cluster_name` external label is injected into all alerts for cluster identification in LogicMonitor.

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
sourceName = "openshift_alertmanager"
```

Delete the test rule when done:

```bash
oc delete -f manifests/test/test-prometheus-rule.yaml -n <namespace>
```

**Option C: Continuous firehose (for LogSource development)**

See `manifests/test/firehose-prometheus-rule.yaml` and `manifests/test/firehose-alertmanager-config.yaml` for a diverse 8-alert firehose that re-fires every 2 minutes. Useful when iterating on LogSource field extraction with real data.

## LogicMonitor Portal Configuration

### LogSource

Import the LogSource definition from `logsource/OpenShift_AlertManager_Webhook.json` via the LM REST API:

```bash
curl -X POST "https://<portal>.logicmonitor.com/santaba/rest/setting/logsources" \
  -H "Authorization: Bearer <your-token>" \
  -H "Content-Type: application/json" \
  -d @logsource/OpenShift_AlertManager_Webhook.json
```

Or create it manually in the portal (Settings > LM Logs > Log Sources > Add).

**Critical:** do NOT add any `SourceName` filter. The URL path segment (`openshift_alertmanager` from the webhook URL) auto-dispatches payloads to this LogSource. A filter value that does not exactly match the URL segment silently routes all logs to the fallback `default.webhook_logsource`.

### Log Fields (24 total)

All extractions use `Dynamic Group Regex` (`RegexGroup`). Free-text fields (description, message, summary, URLs, group_key) use an escape-aware pattern to handle embedded `\"` correctly.

| Key | Regex | Source in payload |
|---|---|---|
| `receiver` | `"receiver"\s*:\s*"([^"]+)"` | Top-level receiver name |
| `status` | `"status"\s*:\s*"([^"]+)"` | Top-level webhook status |
| `alert_status` | `"alerts"\s*:\s*\[\s*\{\s*"status"\s*:\s*"([^"]+)"` | Inner first-alert status |
| `alertname` | `"alertname"\s*:\s*"([^"]+)"` | Alert name |
| `severity` | `"severity"\s*:\s*"([^"]+)"` | Severity |
| `namespace` | `"namespace"\s*:\s*"([^"]+)"` | Kubernetes namespace |
| `cluster_name` | `"cluster_name"\s*:\s*"([^"]+)"` | Cluster label (from externalLabels) |
| `cluster_id` | `https:\/\/[^\/]*?\.apps\.([^.]+)\.` | Cluster DNS segment (from console URL) |
| `component` | `"component"\s*:\s*"([^"]+)"` | Component label |
| `pod` | `"pod"\s*:\s*"([^"]+)"` | Pod label (pod-specific alerts) |
| `alert_source` | `"openshift_io_alert_source"\s*:\s*"([^"]+)"` | platform/user |
| `prometheus` | `"prometheus"\s*:\s*"([^"]+)"` | Prometheus instance |
| `summary` | `"summary"\s*:\s*"((?:[^"\\]|\\.)*)"` | Summary annotation (escape-aware) |
| `description` | `"description"\s*:\s*"((?:[^"\\]|\\.)*)"` | Description annotation (escape-aware) |
| `message` | `"message"\s*:\s*"((?:[^"\\]|\\.)*)"` | Message annotation (escape-aware) |
| `runbook_url` | `"runbook_url"\s*:\s*"((?:[^"\\]|\\.)*)"` | Runbook link (escape-aware) |
| `starts_at` | `"startsAt"\s*:\s*"([^"]+)"` | Alert start timestamp |
| `ends_at` | `"endsAt"\s*:\s*"([^"]+)"` | Alert end timestamp |
| `generator_url` | `"generatorURL"\s*:\s*"((?:[^"\\]|\\.)*)"` | Prometheus query URL |
| `fingerprint` | `"fingerprint"\s*:\s*"([^"]+)"` | Unique alert ID |
| `external_url` | `"externalURL"\s*:\s*"((?:[^"\\]|\\.)*)"` | Cluster console URL |
| `group_key` | `"groupKey"\s*:\s*"((?:[^"\\]|\\.)*)"` | AlertManager group identifier |
| `version` | `"version"\s*:\s*"([^"]+)"` | Webhook schema version |
| `truncated_alerts` | `"truncatedAlerts"\s*:\s*(\d+)` | Truncated batch count (numeric) |

### Resource Mapping (attribute metadata only)

These mappings populate `_resource.attributes` on each log for searchability. They do NOT populate the Resource or Resource Type columns in the UI (webhook platform limitation — see [Resource column behavior](#resource-column-behavior) below).

| Key | Regex | Notes |
|---|---|---|
| `openshift.alert.name` | `"alertname"\s*:\s*"([^"]+)"` | Always populates |
| `openshift.cluster.name` | `"cluster_name"\s*:\s*"([^"]+)"` | Populates when `cluster_name` externalLabel is set |
| `openshift.cluster.id` | `https:\/\/[^\/]*?\.apps\.([^.]+)\.` | Always populates (extracts cluster DNS segment from console URL) |

### Resource Column Behavior

Webhook-based LogSources do not associate ingested logs with specific LM device records — the Resource and Resource Type columns remain empty on every webhook log, regardless of how resource mapping is configured or whether a device has a matching custom property. This was verified against the live portal with every permutation of `Regex`, `RegexGroup`, and `WebhookAttribute` methods, with and without matching device properties, using real AlertManager traffic from an ARO cluster.

If you need log-alert correlation on a specific device in the LM UI, use collector-based ingestion. The Fluentd sidecar pattern (draft manifests in `manifests/fluentd-sidecar/`) receives the AlertManager webhook and re-forwards to LM's Ingest API (`/rest/log/ingest`) with an explicit `_lm.resourceId` header, which does populate the Resource column. A fully-fleshed AlertManager → Fluentd → LM Ingest manifest set is planned.

### Cluster Identity in Alerts

Two ways to identify the source cluster in log queries:

**Option A: externalLabels (recommended)**

Set `cluster_name` as an external label in `user-workload-monitoring-config`. Every alert gets the label injected automatically without modifying individual PrometheusRules. The `cluster_name` logField populates for every log.

**Option B: console URL extraction (fallback)**

When externalLabels are not set, the `cluster_id` logField still extracts the cluster DNS segment (e.g., `qmhkwy1yzd313c0d18` for ARO) from the `externalURL` or `generatorURL` in every payload. AlertManager always emits those URLs, so no customer configuration is required. Use `cluster_id` in LMQL queries when `cluster_name` is absent.

### PrometheusRule Label Requirements

| Label | Purpose | Required |
|---|---|---|
| `namespace` | Routes alert to correct AlertmanagerConfig | Yes |
| `severity` | Matches AlertmanagerConfig route matchers | Yes |
| `cluster_name` | Populates `cluster_name` logField | Optional (use externalLabels or rely on `cluster_id`) |

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
          annotations:
            summary: "High error rate detected"
            description: "Error rate exceeds 10/s"
            runbook_url: "https://runbooks.example.com/high-error-rate"
```

## LMQL Query Reference

```
# All AlertManager webhook logs
sourceName = "openshift_alertmanager"

# Critical alerts only
sourceName = "openshift_alertmanager" AND severity = "critical"

# Specific alert name
sourceName = "openshift_alertmanager" AND alertname = "HighErrorRate"

# Specific cluster (by explicit label)
sourceName = "openshift_alertmanager" AND cluster_name = "my-cluster"

# Specific cluster (by console URL extraction, works without externalLabels)
sourceName = "openshift_alertmanager" AND cluster_id = "qmhkwy1yzd313c0d18"

# Only firing alerts (not resolved)
sourceName = "openshift_alertmanager" AND alert_status = "firing"

# Alerts with runbook links
sourceName = "openshift_alertmanager" AND runbook_url = *

# Search within alert descriptions
sourceName = "openshift_alertmanager" AND "backup failed"

# Alerts by a specific pod
sourceName = "openshift_alertmanager" AND pod = "my-pod-abc123"

# Platform-level alerts
sourceName = "openshift_alertmanager" AND alert_source = "platform"
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

## Operational Notes

**Large LogSource edits have a 2-5 minute propagation lag.** When saving significant changes (adding 10+ logFields, editing resource mappings), LM's webhook ingestion continues processing with the cached old configuration for 2-5 minutes. During the lag, logs may appear with incomplete field extraction or may route to `default.webhook_logsource`. Batch all edits into a single save, then wait 5 minutes before evaluating results. This behavior is undocumented in LM's public docs.

**Webhook URL path segment is the LogSource dispatch key.** The `openshift_alertmanager` segment at the end of `/rest/api/v1/webhook/ingest/openshift_alertmanager` is what LM uses to auto-route payloads to this LogSource. Adding a `SourceName` filter with a different value silently breaks ingestion.

**Escape-aware regex for free-text fields.** Annotation fields (`description`, `message`, `summary`, `runbook_url`) can contain embedded `\"` (JSON-escaped quotes). The pattern `"key"\s*:\s*"((?:[^"\\]|\\.)*)"` handles these correctly. A simpler `([^"]+)` pattern truncates at the first escaped quote.

## Troubleshooting

| Symptom | Resolution |
|---|---|
| AlertmanagerConfig not applied | Verify namespace and AlertmanagerConfig both have `openshift.io/user-monitoring: "true"` label |
| Routes not in generated config | Ensure `enableAlertmanagerConfig: true` is set in `user-workload-monitoring-config` ConfigMap |
| Webhook returns 401 | Check Bearer token is correct, not expired, and has LM Logs permissions |
| Webhook returns 202 but no logs | Verify API user has `lm_logs_administrator` role. Check LogSource has NO `SourceName` filter. |
| Logs show `_lm.logsource_name = "default.webhook_logsource"` | LogSource filter misconfigured or webhook URL path segment doesn't match any LogSource. Remove any `SourceName` filter. |
| Alerts not reaching LM | Add explicit `namespace` label to PrometheusRule alert definitions |
| New logFields not populating after save | Normal — wait 2-5 minutes for LogSource cache propagation |
| Resource column empty on logs | Expected — webhook ingestion doesn't populate Resource column. Use collector-based (Fluentd) ingestion if required. |
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
- [Webhook LogSource Configuration](https://www.logicmonitor.com/support/webhook-logsource-configuration)
- [LMQL Reference](https://www.logicmonitor.com/support/logicmonitor-query-language-reference)
- [OpenShift User Workload Monitoring](https://docs.redhat.com/en/documentation/openshift_container_platform/4.16/html/monitoring/enabling-monitoring-for-user-defined-projects)
- [AlertmanagerConfig CRD](https://docs.redhat.com/en/documentation/openshift_container_platform/4.16/html/monitoring_apis/alertmanagerconfig-monitoring-coreos-com-v1beta1)
