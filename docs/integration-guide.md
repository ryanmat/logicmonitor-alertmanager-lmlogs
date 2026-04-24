# Prometheus AlertManager Integration with LogicMonitor LM Logs

Forward Prometheus AlertManager alerts into LogicMonitor as structured webhook logs. Works with any OpenShift distribution (ARO, ROSA, self-managed) running version 4.12 or later.

## Architecture

```
Prometheus --> AlertManager --> LM Webhook LogSource --> LM Logs --> LogAlerts
```

1. Prometheus evaluates alerting rules defined in PrometheusRules.
2. AlertManager receives alerts and routes them based on labels (namespace, severity).
3. AlertManager POSTs a JSON payload to the LogicMonitor webhook endpoint.
4. The LogicMonitor LogSource parses the payload and extracts 24 structured fields.
5. Logs are queryable by `sourceName`, `cluster_name`, `alertname`, `severity`, and other extracted fields.
6. LogAlerts evaluate log patterns and generate LogicMonitor alerts.

## Known Limitation

Webhook-based logs do NOT populate the Resource or Resource Type columns in the LM Logs UI. This is a platform behavior of LM's webhook ingestion pipeline, not a configuration issue. We verified this with every permutation of Regex/RegexGroup/WebhookAttribute methods, with and without matching device properties, against real AlertManager traffic.

For log-to-alert correlation on a specific device in the LM UI, use the Fluentd forwarder path described in Section 15. Alerts routed through the forwarder are ingested via LM's `/rest/log/ingest` endpoint with an explicit `_lm.resourceId` resolved from a device property match — that IS the mechanism that populates the Resource column.

## Prerequisites

| Requirement | Details |
|---|---|
| OpenShift Version | 4.12 or later |
| User Workload Monitoring | Enabled on the cluster |
| Permissions | cluster-admin or monitoring-edit role |
| Network Egress | HTTPS (443) to your LogicMonitor portal |
| LM Logs | Enabled on your LogicMonitor portal |
| LM API User | Bearer token with `lm_logs_administrator` role |

## 1. Enable User Workload Monitoring

Two ConfigMaps are required. The first enables user workload monitoring. The second enables the user workload AlertManager and AlertmanagerConfig reconciliation.

### Step 1a: Enable User Workload Monitoring

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

### Step 1b: Enable AlertManager, AlertmanagerConfig, and External Labels

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

Both `enabled: true` and `enableAlertmanagerConfig: true` are required. The first creates the AlertManager pods. The second tells the operator to reconcile AlertmanagerConfig CRDs from labeled namespaces. Without `enableAlertmanagerConfig`, AlertmanagerConfig resources are ignored.

The `cluster_name` external label is injected into all alerts automatically. This is the preferred way to provide the cluster name. If you cannot set external labels, the LogSource also extracts `cluster_id` from the AlertManager `externalURL` (the OpenShift console hostname), which works without any Prometheus configuration.

### Verify

```bash
# User workload monitoring namespace exists
oc get namespace openshift-user-workload-monitoring

# AlertManager pods are running
oc get pods -n openshift-user-workload-monitoring -l app.kubernetes.io/name=alertmanager
```

Both should show Active/Running status.

## 2. Create LM API User and Bearer Token

1. In LogicMonitor, navigate to Settings > Users and Roles.
2. Click Add > Add User.
3. Set username (e.g., `openshift_alertmanager_webhook`).
4. Assign the `lm_logs_administrator` role. The `manager` role alone returns HTTP 202 but silently drops logs.
5. Generate a Bearer Token under User Settings > LMv1 API Tokens > Add.
6. Copy the token (starts with `lmb_`). Store it securely.

## 3. Create the LogSource

Import the LogSource definition from `logsource/OpenShift_AlertManager_Webhook.json` in the repository. This is the recommended approach to avoid manual configuration errors.

```bash
curl -X POST "https://<portal>.logicmonitor.com/santaba/rest/setting/logsources" \
  -H "Authorization: Bearer <your-token>" \
  -H "Content-Type: application/json" \
  -H "X-Version: 3" \
  -d @logsource/OpenShift_AlertManager_Webhook.json
```

The `X-Version: 3` header is required — the LM REST endpoint silently rejects the payload under the default older API version with a generic HTTP 400. The same JSON imported through the portal UI (Settings > LogSources > Add > Import from JSON) works without thinking about API version.

Alternatively, create it manually in the portal (Settings > LM Logs > Log Sources > Add):

- Name: `OpenShift_AlertManager_Webhook`
- Type: Webhook
- Filters: **None** (do NOT add a SourceName filter)

**Once imported, do not delete-and-recreate the LogSource.** Webhook URL→LogSource dispatch on LM is backed by an opaque server-side cache that breaks under repeated recreate cycles — payloads continue returning HTTP 202 Accepted but logs land in `default.webhook_logsource` instead of this LogSource. Recovery requires importing a fresh copy via the portal UI and waiting at least 10 minutes. If you need to change the LogSource definition, prefer in-place PUT updates over delete+create.

### Critical Configuration Rules

1. **No filters.** The URL path segment (`openshift_alertmanager` from the webhook URL) auto-dispatches payloads to this LogSource. A `SourceName` filter with a value that does not exactly match the URL segment silently routes all logs to the fallback `default.webhook_logsource`.

2. **Use `RegexGroup` method (not `Regex`) for all regex-based logFields.** The `Regex` method stores the entire regex match; `RegexGroup` stores just the capture group contents.

3. **Use escape-aware patterns for free-text fields.** Annotation fields (`description`, `message`, `summary`, `runbook_url`, `group_key`) can contain embedded `\"`. Use `((?:[^"\\]|\\.)*)` instead of `([^"]+)` to capture the full value.

### Field Extraction (24 Fields)

All logFields use `Dynamic Group Regex` (`RegexGroup`) method.

| Field | Regex | Source in payload |
|---|---|---|
| `receiver` | `"receiver"\s*:\s*"([^"]+)"` | Top-level receiver name |
| `status` | `"status"\s*:\s*"([^"]+)"` | Top-level webhook status |
| `alert_status` | `"alerts"\s*:\s*\[\s*\{\s*"status"\s*:\s*"([^"]+)"` | Inner first-alert status |
| `alertname` | `"alertname"\s*:\s*"([^"]+)"` | Alert name |
| `severity` | `"severity"\s*:\s*"([^"]+)"` | Severity |
| `namespace` | `"namespace"\s*:\s*"([^"]+)"` | Kubernetes namespace |
| `cluster_name` | `"cluster_name"\s*:\s*"([^"]+)"` | Cluster label (from externalLabels) |
| `cluster_id` | `https:\/\/[^\/]*?\.apps\.([^.]+)\.` | Cluster DNS segment (from console URL) |
| `component` | `"component"\s*:\s*"([^"]+)"` | Component label (when present) |
| `pod` | `"pod"\s*:\s*"([^"]+)"` | Pod label (pod-specific alerts) |
| `alert_source` | `"openshift_io_alert_source"\s*:\s*"([^"]+)"` | platform/user |
| `prometheus` | `"prometheus"\s*:\s*"([^"]+)"` | Prometheus instance |
| `summary` | `"summary"\s*:\s*"((?:[^"\\]|\\.)*)"` | Summary annotation |
| `description` | `"description"\s*:\s*"((?:[^"\\]|\\.)*)"` | Description annotation |
| `message` | `"message"\s*:\s*"((?:[^"\\]|\\.)*)"` | Message annotation |
| `runbook_url` | `"runbook_url"\s*:\s*"((?:[^"\\]|\\.)*)"` | Runbook link |
| `starts_at` | `"startsAt"\s*:\s*"([^"]+)"` | Alert start timestamp |
| `ends_at` | `"endsAt"\s*:\s*"([^"]+)"` | Alert end timestamp |
| `generator_url` | `"generatorURL"\s*:\s*"((?:[^"\\]|\\.)*)"` | Prometheus query URL |
| `fingerprint` | `"fingerprint"\s*:\s*"([^"]+)"` | Unique alert ID |
| `external_url` | `"externalURL"\s*:\s*"((?:[^"\\]|\\.)*)"` | Cluster console URL |
| `group_key` | `"groupKey"\s*:\s*"((?:[^"\\]|\\.)*)"` | AlertManager group identifier |
| `version` | `"version"\s*:\s*"([^"]+)"` | Webhook schema version |
| `truncated_alerts` | `"truncatedAlerts"\s*:\s*(\d+)` | Truncated batch count (numeric, not quoted) |

### Resource Mapping

These mappings populate `_resource.attributes` on each log for metadata searchability. They do NOT populate the Resource or Resource Type columns in the UI — see the Known Limitation section above.

| Method | Key | Value | Purpose |
|---|---|---|---|
| RegexGroup | `openshift.instance.name` | `"instance_name"\s*:\s*"([^"]+)"` | Instance name attribute (extracts only when an `instance_name` label is present) |
| RegexGroup | `openshift.alert.name` | `"alertname"\s*:\s*"([^"]+)"` | Alert name attribute (always populates) |
| Regex | `a_genURL` | `^https:\/\/[^\/]*?\.apps\.([^.]+)\.` | Cluster ID from console URL — kept for compatibility with the SMBC-derived reference LogSource. The `^` anchor and `Regex` method mean this mapping never extracts a value against an AlertManager payload, but it does not block dispatch. The cluster identifier is reliably available via the `cluster_id` logField (without the anchor). |

WebHook LogSources require at least one resource mapping configured at create time (the LM API rejects an empty `resourceMapping` array on a `WEBHOOK` LogSource). The three mappings above are the proven-working set carried over from the SMBC reference — leave them in place.

## 4. Prepare the Target Namespace

Label the namespace where you will deploy the AlertmanagerConfig:

```bash
oc label namespace <namespace> \
  openshift.io/cluster-monitoring=false \
  openshift.io/user-monitoring=true \
  --overwrite
```

## 5. Deploy the Bearer Token Secret

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: logicmonitor-bearer-token
  namespace: <namespace>
type: Opaque
stringData:
  token: "<your-bearer-token>"
```

```bash
oc apply -f bearer-token-secret.yaml -n <namespace>
```

## 6. Deploy the AlertmanagerConfig

```yaml
apiVersion: monitoring.coreos.com/v1beta1
kind: AlertmanagerConfig
metadata:
  name: logicmonitor-webhook
  namespace: <namespace>
  labels:
    openshift.io/user-monitoring: "true"
spec:
  route:
    receiver: logicmonitor-webhook
    matchers:
      - name: severity
        matchType: "=~"
        value: "critical|warning"
    continue: true
    groupBy:
      - alertname
      - namespace
    groupWait: 30s
    groupInterval: 5m
    repeatInterval: 4h
  receivers:
    - name: logicmonitor-webhook
      webhookConfigs:
        - url: "https://<portal>.logicmonitor.com/rest/api/v1/webhook/ingest/openshift_alertmanager"
          sendResolved: true
          httpConfig:
            authorization:
              type: Bearer
              credentials:
                name: logicmonitor-bearer-token
                key: token
```

Replace `<portal>` with your LogicMonitor portal name.

```bash
oc apply -f alertmanager-config.yaml -n <namespace>
```

### Configuration Parameters

| Parameter | Description | Recommended Value |
|---|---|---|
| groupWait | Time before sending first notification | 30s |
| groupInterval | Time between notifications for same group | 5m |
| repeatInterval | Time before re-sending a notification | 4h |
| continue | Allow alert to match additional routes | true |
| sendResolved | Send notification when alert resolves | true |

## 7. PrometheusRule Requirements

Alert rules MUST include explicit labels for routing:

| Label | Purpose | Required |
|---|---|---|
| namespace | Routes alert to correct AlertmanagerConfig | Yes |
| severity | Matches AlertmanagerConfig route matchers | Yes |
| cluster_name | Identifies cluster in LogicMonitor | Optional (use externalLabels from Step 1b, or rely on `cluster_id` extraction from URL) |

When using `leaf-prometheus` scope, the namespace label is not automatically injected. Alerts without the namespace label will not match any route.

If you configured `cluster_name` as an external label in Step 1b, you do not need to add it to individual PrometheusRules. It is injected into all alerts automatically.

Example PrometheusRule:

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
            description: "Error rate exceeds 10 errors/second"
            runbook_url: "https://runbooks.example.com/high-error-rate"
```

## 8. Verification

### Test Webhook Directly

```bash
curl -X POST "https://<portal>.logicmonitor.com/rest/api/v1/webhook/ingest/openshift_alertmanager" \
  -H "Authorization: Bearer <your-token>" \
  -H "Content-Type: application/json" \
  -d '{
    "status": "firing",
    "alerts": [{
      "status": "firing",
      "labels": {
        "alertname": "TestAlert",
        "severity": "warning",
        "namespace": "test",
        "cluster_name": "<your-cluster-name>"
      },
      "annotations": {
        "summary": "Test alert for webhook verification"
      },
      "startsAt": "2026-04-21T00:00:00Z",
      "endsAt": "0001-01-01T00:00:00Z",
      "generatorURL": "https://console-openshift-console.apps.<cluster-dns>/monitoring/graph",
      "fingerprint": "testfp"
    }],
    "externalURL": "https://console-openshift-console.apps.<cluster-dns>/monitoring",
    "version": "4"
  }'
```

Expected response: `Accepted` (HTTP 202).

### Verify AlertmanagerConfig

```bash
oc get alertmanagerconfig -A -l openshift.io/user-monitoring=true
```

### Verify Generated Configuration

```bash
oc get secret alertmanager-user-workload-generated \
  -n openshift-user-workload-monitoring \
  -o jsonpath='{.data.alertmanager\.yaml\.gz}' | base64 -d | gunzip
```

### Verify in LM Logs

```
sourceName = "openshift_alertmanager"
```

Wait up to ~2 minutes for the alert to route through AlertManager grouping. If using the direct curl test above, the log appears within seconds.

## 9. LMQL Query Reference

```
# All AlertManager webhook logs
sourceName = "openshift_alertmanager"

# Critical alerts only
sourceName = "openshift_alertmanager" AND severity = "critical"

# Specific alert name
sourceName = "openshift_alertmanager" AND alertname = "HighErrorRate"

# Specific cluster by label (requires externalLabels)
sourceName = "openshift_alertmanager" AND cluster_name = "my-cluster"

# Specific cluster by URL extraction (works without externalLabels)
sourceName = "openshift_alertmanager" AND cluster_id = "qmhkwy1yzd313c0d18"

# Only firing alerts (not resolved)
sourceName = "openshift_alertmanager" AND alert_status = "firing"

# Alerts with runbook links
sourceName = "openshift_alertmanager" AND runbook_url = *

# Alerts by a specific pod (pod-level alerts only)
sourceName = "openshift_alertmanager" AND pod = "my-pod-abc123"

# Platform alerts (vs user workload)
sourceName = "openshift_alertmanager" AND alert_source = "platform"

# Search within alert descriptions
sourceName = "openshift_alertmanager" AND "backup failed"
```

## 10. Adding New Namespaces

Repeat for each namespace that needs alert forwarding:

```bash
# 1. Label namespace
oc label namespace <namespace> \
  openshift.io/cluster-monitoring=false \
  openshift.io/user-monitoring=true \
  --overwrite

# 2. Deploy secret
oc create secret generic logicmonitor-bearer-token \
  --from-literal=token="<bearer-token>" \
  -n <namespace>

# 3. Deploy AlertmanagerConfig
oc apply -f alertmanager-config.yaml -n <namespace>

# 4. Verify
oc get alertmanagerconfig -n <namespace>
```

## 11. Bearer Token Rotation

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

## 12. Managed Platform Notes (ARO, ROSA)

On managed OpenShift platforms (Azure Red Hat OpenShift, Red Hat OpenShift on AWS), the `openshift-monitoring` namespace is managed by the cloud provider and Red Hat SRE:

- You cannot modify the platform AlertManager configuration.
- You cannot add custom receivers to the platform AlertManager.
- Platform alerts route to Red Hat SRE by default.

All custom webhook routing must go through user workload monitoring, which is what this guide configures.

To receive platform-level alerts in LogicMonitor, create a dedicated namespace (e.g., `platform-alerts`), deploy PrometheusRules that query kube-state-metrics for infrastructure conditions, and route through the user workload AlertManager.

ARO clusters have egress lockdown enabled by default. Whitelist `*.logicmonitor.com` on port 443 in your firewall rules if outbound webhooks are blocked.

## 13. Operational Notes

### LogSource Edit Propagation Lag (2-5 minutes)

When saving significant changes to the LogSource (adding 10+ logFields, editing resource mappings), LM's webhook ingestion continues processing with the cached old configuration for 2-5 minutes. During the lag:

- Logs may appear with incomplete field extraction
- Logs may route to `default.webhook_logsource`

Batch all edits into a single save and wait 5 minutes before evaluating results. This behavior is undocumented in LM's public docs.

### Webhook URL Path Segment Drives Dispatch

The `openshift_alertmanager` segment at the end of the webhook URL is what LM uses to auto-dispatch payloads to this LogSource. If you change the URL path, you must create a new LogSource named to match.

### Escape-Aware Regex Required for Free-Text Fields

Annotation fields (`description`, `message`, `summary`, `runbook_url`) can contain embedded `\"` (JSON-escaped quotes). The pattern `((?:[^"\\]|\\.)*)` handles these correctly. A simpler `([^"]+)` pattern truncates at the first escaped quote, producing truncated field values silently.

### Resource Column Does Not Populate for Webhook Logs

We tested every permutation of resource mapping (Regex, RegexGroup, WebhookAttribute methods; every combination of key/value patterns; with and without matching device custom properties) against real AlertManager traffic. The Resource and Resource Type columns in LM Logs never populate for webhook-ingested logs. This is a platform limitation.

If you need per-device log correlation, use the Fluentd forwarder described in Section 15 (`manifests/fluentd-alertmanager-forwarder/`). Fluentd receives the AlertManager webhook, enriches the record with the cluster identity, and re-POSTs to LM's Ingest API (`/rest/log/ingest`) with `resource_mapping` resolving `_lm.resourceId` from a device property — which DOES populate the Resource column.

## 14. Troubleshooting

| Symptom | Resolution |
|---|---|
| AlertmanagerConfig not applied | Verify namespace and AlertmanagerConfig both have `openshift.io/user-monitoring: "true"` label |
| Webhook returns 401 | Check Bearer token is correct and has LM Logs permissions |
| Webhook returns 202 but no logs | Verify API user has `lm_logs_administrator` role. Check LogSource has NO `SourceName` filter. |
| Logs show `_lm.logsource_name = "default.webhook_logsource"` | LogSource is not matching the payload. Remove any `SourceName` filter; webhook URL path auto-dispatches by segment. |
| Alerts not reaching LM | Add explicit `namespace` label to PrometheusRule alert definitions |
| New logFields not populating after save | Wait 2-5 minutes for LogSource cache propagation |
| Free-text fields (description, message) look truncated | Regex pattern must be escape-aware: use `((?:[^"\\]|\\.)*)` not `([^"]+)` |
| `cluster_id` logField empty | Regex must NOT have `^` anchor — LM's input is the full payload, not just the URL |
| Resource column empty | Expected — webhook ingestion does not populate Resource. Follow Section 15 to deploy the Fluentd forwarder for per-device correlation. |
| Egress blocked (managed platforms) | Whitelist `*.logicmonitor.com:443` in egress firewall rules |

## 15. Advanced: Device-correlated logs via Fluentd forwarder

The webhook path in Sections 1-14 is the default integration and satisfies most use cases. If you specifically need the **Resource** column in LM Logs populated for per-device log correlation (navigation from an alert to the device view, per-device LMQL filters on `_resource.name`, device-scoped alert rules), deploy the Fluentd forwarder.

### Architecture

```
Prometheus → AlertManager → [in-cluster Fluentd HTTP receiver, port 9880]
                            → record_transformer injects cluster_name from env
                            → @type lm output: resource_mapping + bearer auth
                            → POST /rest/log/ingest
                            → LM matches cluster_name against device property
                            → log bound to matched device, Resource column populated
```

The forwarder is a 1-replica Deployment. AlertManager POSTs to an in-cluster ClusterIP Service; the Fluentd pod re-emits each payload to LogicMonitor's `/rest/log/ingest` endpoint with the `@type lm` output plugin. `resource_mapping` binds the log to the LM device whose `openshift.cluster.name` property matches the cluster name injected at pod deploy time.

### Prerequisites

- Everything from Sections 1-2 already in place (User Workload Monitoring enabled, Bearer token available, `logicmonitor-bearer-token` Secret deployed in the target namespace).
- LM device representing your OpenShift cluster has a custom property `openshift.cluster.name` set to the value you will pass as `CLUSTER_NAME` below. Set via the LM portal (Resources > [device] > Info > Properties > Add) or via API:
  ```
  curl -X PUT "https://<portal>.logicmonitor.com/santaba/rest/device/devices/<id>/properties/openshift.cluster.name" \
    -H "Authorization: Bearer <token>" \
    -H "Content-Type: application/json" \
    -H "X-Version: 3" \
    -d '{"name": "openshift.cluster.name", "value": "<your-cluster-name>"}'
  ```

### Deploy the forwarder

The manifests live in `manifests/fluentd-alertmanager-forwarder/`:

```
configmap.yaml       # Fluentd config (source, filter, match)
deployment.yaml      # logicmonitor/lm-logs-k8s-fluentd:1.4.0 Deployment
service.yaml         # ClusterIP on port 9880
networkpolicy.yaml   # Allow ingress only from openshift-user-workload-monitoring
kustomization.yaml
```

1. Edit `deployment.yaml` to replace the two env placeholders:
   - `CLUSTER_NAME` — the value of your `openshift.cluster.name` device property
   - `LM_COMPANY_NAME` — your LM portal name (the `<portal>` in `https://<portal>.logicmonitor.com`)
2. Apply:
   ```
   oc apply -k manifests/fluentd-alertmanager-forwarder/ -n <namespace>
   ```
3. Verify the pod is Running and the HTTP receiver is listening:
   ```
   oc rollout status deploy/lm-logs-forwarder -n <namespace>
   oc logs deploy/lm-logs-forwarder -n <namespace> --tail=40
   ```
   Expected log lines on startup: `starting fluentd`, `following tail of ...` (none for this config), `fluentd worker is now running`.

### Route AlertManager to the forwarder

Add a new AlertmanagerConfig alongside the existing webhook one. A reference is at `manifests/test/firehose-alertmanager-config-fluentd.yaml`. Minimum viable config for your workload:

```yaml
apiVersion: monitoring.coreos.com/v1beta1
kind: AlertmanagerConfig
metadata:
  name: logicmonitor-forwarder
  namespace: <namespace>
  labels:
    openshift.io/user-monitoring: "true"
spec:
  route:
    receiver: logicmonitor-forwarder
    matchers:
      - name: severity
        matchType: "=~"
        value: "critical|warning"
    continue: true
    groupBy:
      - alertname
      - namespace
    groupWait: 30s
    groupInterval: 5m
    repeatInterval: 4h
  receivers:
    - name: logicmonitor-forwarder
      webhookConfigs:
        - url: "http://lm-logs-forwarder.<namespace>.svc.cluster.local:9880/alertmanager.webhook"
          sendResolved: true
```

The URL path segment `alertmanager.webhook` becomes the Fluentd event tag; the ConfigMap's `<match alertmanager.**>` picks it up. The forwarder Service is ClusterIP and the NetworkPolicy restricts ingress to `openshift-user-workload-monitoring`, so no external auth is needed between AlertManager and Fluentd. Authentication to LogicMonitor happens Fluentd → LM over HTTPS with the Bearer token.

### Credentials

The forwarder reuses the same `logicmonitor-bearer-token` Secret as the webhook path. The `lm_logs_administrator` role accepts both the webhook ingest and the log ingest endpoints. If you prefer independent rotation between the two paths, create a separate LM API user (e.g. `openshift_alertmanager_fluentd`) with the same role and deploy a second Secret; point the Deployment at that Secret instead.

### Verification

Query LM Logs for a forwarder log:

```
event_source = "alertmanager" AND _resource.name = "<your-cluster-name>"
```

The log's Resource column should show the device name, and clicking through should navigate to the device view. The log message is the raw AlertManager webhook JSON (the same payload the webhook path receives), so all LMQL substring filters work unchanged (`"alertname":"HighErrorRate"`, etc.).

### When to prefer which path

| Customer need | Path |
|---|---|
| Fast 5-minute onboarding, no new pods | Webhook (Sections 1-14) |
| Resource column populated in LM Logs | Fluentd forwarder (this section) |
| Per-device alert rules based on log content | Fluentd forwarder |
| Strict minimum cluster footprint | Webhook |
| Customer already runs lm-logs-k8s Helm chart for pod logs | Fluentd forwarder — deploys alongside, does not interact |

The two paths coexist. Running both forwards each alert twice (once via webhook, once via Fluentd) and produces two log rows in LM Logs with `event_source` distinguishing them. Most deployments pick one.

### Troubleshooting

| Symptom | Resolution |
|---|---|
| Fluentd pod CrashLoopBackOff with "no such file: fluent.conf" | The ConfigMap name in `deployment.yaml` volumes must match the ConfigMap metadata.name |
| Pod Running but no logs in LM after 5 min | Check `oc logs deploy/lm-logs-forwarder` for `401` (bad Bearer token) or `404` (`company_name` env wrong) |
| Logs reach LM but Resource column still empty | Device is missing the `openshift.cluster.name` property, or the property value does not match the `CLUSTER_NAME` env on the pod exactly (case-sensitive on the value, property name is stored lowercase by LM) |
| AlertManager reports connection refused to Fluentd | NetworkPolicy blocking — verify `openshift-user-workload-monitoring` namespace has the `kubernetes.io/metadata.name` label (this is an auto-label on OpenShift 4.12+; if missing, add it) |
| Fluentd logs show buffer overflow | Increase `chunk_limit_size` and `total_limit_size` in `configmap.yaml` under the `<buffer>` block |
