# Prometheus AlertManager Integration with LogicMonitor LM Logs

Forward Prometheus AlertManager alerts into LogicMonitor as structured webhook logs. Works with any OpenShift distribution (ARO, ROSA, self-managed) running version 4.12 or later.

## Architecture

```
Prometheus --> AlertManager --> LM Webhook LogSource --> LM Logs --> LogAlerts
```

1. Prometheus evaluates alerting rules defined in PrometheusRules.
2. AlertManager receives alerts and routes them based on labels (namespace, severity).
3. AlertManager POSTs a JSON payload to the LogicMonitor webhook endpoint.
4. The LogicMonitor LogSource parses the payload and extracts structured fields.
5. Resource mapping stores cluster and alert attributes on log entries.
6. LogAlerts evaluate log patterns and generate LogicMonitor alerts.

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

The `cluster_name` external label is injected into all alerts automatically. This is the recommended way to provide the cluster name for LogicMonitor resource identification, rather than adding it to every PrometheusRule individually.

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
  -d @logsource/OpenShift_AlertManager_Webhook.json
```

Alternatively, create it manually in the portal (Settings > LM Logs > Log Sources > Add):

- Name: `OpenShift_AlertManager_Webhook`
- Type: Webhook
- Filters: None (do not add a SourceName filter)

### Field Extraction

The LogSource uses two extraction methods for reliability. WebhookAttribute uses JSONPath to access structured fields. RegexGroup uses regex on the raw payload body as a fallback.

| Field Name | Method | Value | Description |
|---|---|---|---|
| status | WebhookAttribute | `$.status` | Alert state (firing/resolved) |
| receiver | WebhookAttribute | `$.receiver` | AlertManager receiver name |
| alertname | WebhookAttribute | `$.alerts[*].labels.alertname` | Name of the alert |
| namespace | WebhookAttribute | `$.alerts[*].labels.namespace` | Kubernetes namespace |
| severity | WebhookAttribute | `$.alerts[*].labels.severity` | Alert severity level |
| summary | WebhookAttribute | `$.alerts[*].annotations.summary` | Alert summary |
| nodename | WebhookAttribute | `$.alerts[*].labels.instance_name` | Node or instance name |
| a_alertname | RegexGroup | `"alertname"\s*:\s*"([^"]+)"` | Alert name (regex fallback) |
| a_severity | RegexGroup | `"severity"\s*:\s*"([^"]+)"` | Severity (regex fallback) |
| a_summary | RegexGroup | `"summary"\s*:\s*"([^"]+)"` | Summary (regex fallback) |
| a_description | RegexGroup | `"description"\s*:\s*"((?:[^"\\]|\\.)*)"` | Description (regex fallback) |
| a_pod | RegexGroup | `"pod"\s*:\s*"([^"]+)"` | Pod name |
| a_nodename | RegexGroup | `"instance_name"\s*:\s*"([^"]+)"` | Instance name (regex fallback) |
| a_genURL | RegexGroup | `"generatorURL"\s*:\s*"((?:[^"\\]|\\.)*)"` | Prometheus graph URL |

### Resource Mapping

Resource mapping extracts attributes stored on each log entry in `_resource.attributes`. These are metadata fields for querying and identification. Webhook-based logs do not populate the Resource or Resource Type columns in LM Logs (this is a platform limitation for webhook ingestion).

| Method | Key | Value | Purpose |
|---|---|---|---|
| RegexGroup | `openshift.instance.name` | `"instance_name"\s*:\s*"([^"]+)"` | Instance name attribute |
| RegexGroup | `openshift.alert.name` | `"alertname"\s*:\s*"([^"]+)"` | Alert name attribute |
| RegexGroup | `openshift.cluster.name` | `"cluster_name"\s*:\s*"([^"]+)"` | Cluster name attribute |

## 4. Add Cluster Property

For each monitored cluster:

1. Navigate to Resources and find your Kubernetes cluster resource.
2. Go to Info tab > Properties.
3. Click Add > Add Custom Property.
4. Set Name: `openshift.cluster.name`, Value: your cluster name.

The cluster name must match the `cluster_name` label used in your PrometheusRule definitions.

## 5. Prepare the Target Namespace

Label the namespace where you will deploy the AlertmanagerConfig:

```bash
oc label namespace <namespace> \
  openshift.io/cluster-monitoring=false \
  openshift.io/user-monitoring=true \
  --overwrite
```

## 6. Deploy the Bearer Token Secret

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

## 7. Deploy the AlertmanagerConfig

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

## 8. PrometheusRule Requirements

Alert rules MUST include explicit labels for routing:

| Label | Purpose | Required |
|---|---|---|
| namespace | Routes alert to correct AlertmanagerConfig | Yes |
| severity | Matches AlertmanagerConfig route matchers | Yes |
| cluster_name | Identifies cluster in LM Logs | Provided by external labels (Step 1b) |

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
```

## 9. Verification

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
      }
    }]
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

Query:

```
_lm.logsource_name = "OpenShift_AlertManager_Webhook"
```

## 10. LMQL Query Reference

```
# All AlertManager webhook logs
_lm.logsource_name = "OpenShift_AlertManager_Webhook"

# Critical severity alerts
_lm.logsource_name = "OpenShift_AlertManager_Webhook" AND a_severity = "critical"

# Specific alert name
_lm.logsource_name = "OpenShift_AlertManager_Webhook" AND a_alertname = "HighErrorRate"

# Specific cluster
_lm.logsource_name = "OpenShift_AlertManager_Webhook" AND a_nodename = "my-cluster"

# Search within alert descriptions
_lm.logsource_name = "OpenShift_AlertManager_Webhook" AND "backup failed"
```

## 11. Adding New Namespaces

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

## 12. Bearer Token Rotation

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

## 13. Managed Platform Notes (ARO, ROSA)

On managed OpenShift platforms (Azure Red Hat OpenShift, Red Hat OpenShift on AWS), the `openshift-monitoring` namespace is managed by the cloud provider and Red Hat SRE:

- You cannot modify the platform AlertManager configuration.
- You cannot add custom receivers to the platform AlertManager.
- Platform alerts route to Red Hat SRE by default.

All custom webhook routing must go through user workload monitoring, which is what this guide configures.

To receive platform-level alerts in LogicMonitor, create a dedicated namespace (e.g., `platform-alerts`), deploy PrometheusRules that query kube-state-metrics for infrastructure conditions, and route through the user workload AlertManager.

ARO clusters have egress lockdown enabled by default. Whitelist `*.logicmonitor.com` on port 443 in your firewall rules if outbound webhooks are blocked.

## 14. Troubleshooting

| Symptom | Resolution |
|---|---|
| AlertmanagerConfig not applied | Verify namespace and AlertmanagerConfig both have `openshift.io/user-monitoring: "true"` label |
| Webhook returns 401 | Check Bearer token is correct and has LM Logs permissions |
| Webhook returns 202 but no logs | Verify API user has `lm_logs_administrator` role. Check LogSource uses JSONPath for WebhookAttribute values (e.g., `$.status` not `status`). Do not add SourceName filters. |
| Alerts not reaching LM | Add explicit `namespace` label to PrometheusRule alert definitions |
| No Resource/Resource Type on logs | This is a platform limitation for webhook-based ingestion. Logs are queryable by `_lm.logsource_name` and extracted fields. |
| Egress blocked (managed platforms) | Whitelist `*.logicmonitor.com:443` in egress firewall rules |
