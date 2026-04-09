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
5. Resource mapping correlates logs to monitored Kubernetes cluster resources.
6. LogAlerts evaluate log patterns and generate LogicMonitor alerts.

## Prerequisites

| Requirement | Details |
|---|---|
| OpenShift Version | 4.12 or later |
| User Workload Monitoring | Enabled on the cluster |
| Permissions | cluster-admin or monitoring-edit role |
| Network Egress | HTTPS (443) to your LogicMonitor portal |
| LM Logs | Enabled on your LogicMonitor portal |
| LM API User | Bearer token with log ingestion permissions |

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

### Step 1b: Enable AlertManager and AlertmanagerConfig

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

Both `enabled: true` and `enableAlertmanagerConfig: true` are required. The first creates the AlertManager pods. The second tells the operator to reconcile AlertmanagerConfig CRDs from labeled namespaces. Without `enableAlertmanagerConfig`, AlertmanagerConfig resources are ignored.

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
4. Assign a role with LM Logs ingestion permissions (DataIngestion permission required).
5. Generate a Bearer Token under User Settings > LMv1 API Tokens > Add.
6. Copy the token (starts with `lmb_`). Store it securely.

## 3. Create the LogSource

1. Navigate to Settings > LM Logs > Log Sources.
2. Click Add Log Source.
3. Configure:
   - Name: `OpenShift_AlertManager_Webhook`
   - Group: `OpenShift`
   - Type: Webhook
   - Authentication: Bearer Token

### Source Filter

| Attribute | Operator | Value |
|---|---|---|
| SourceName | Equal | `openshift_alertmanager` |

### Field Extraction

Add the following log fields:

| Field Name | Method | Value | Description |
|---|---|---|---|
| status | WebhookAttribute | status | Alert state (firing/resolved) |
| alertname | Regex | `"alertname":"([^"]+)"` | Name of the alert |
| namespace | Regex | `"namespace":"([^"]+)"` | Kubernetes namespace |
| severity | Regex | `"severity":"([^"]+)"` | Alert severity level |
| cluster_name | Regex | `"cluster_name":"([^"]+)"` | Cluster identifier |
| receiver | WebhookAttribute | receiver | AlertManager receiver name |
| instance | Regex | `"instance":"([^"]+)"` | Alert instance |
| source_type | Static | prometheus_alertmanager | Source identifier |

### Resource Mapping

| Method | Key | Value |
|---|---|---|
| Dynamic Group Regex | `openshift.cluster.name` | `"cluster_name"\s*:\s*"([^"]+)"` |

This regex extracts the cluster name from the JSON payload and matches it against resources where the property `openshift.cluster.name` equals the extracted value.

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

Alert rules MUST include explicit labels for routing and resource mapping:

| Label | Purpose | Required |
|---|---|---|
| namespace | Routes alert to correct AlertmanagerConfig | Yes |
| cluster_name | Enables resource mapping in LogicMonitor | Yes |
| severity | Matches AlertmanagerConfig route matchers | Yes |

When using `leaf-prometheus` scope, the namespace label is not automatically injected. Alerts without the namespace label will not match any route.

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
            cluster_name: my-cluster
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
source_type="prometheus_alertmanager" AND alertname="TestAlert"
```

## 10. LMQL Query Reference

```
# All AlertManager logs
source_type="prometheus_alertmanager"

# Firing alerts only
source_type="prometheus_alertmanager" AND status="firing"

# Resolved alerts
source_type="prometheus_alertmanager" AND status="resolved"

# Critical severity
source_type="prometheus_alertmanager" AND severity="critical"

# Specific namespace
source_type="prometheus_alertmanager" AND namespace="production"

# Specific cluster
source_type="prometheus_alertmanager" AND cluster_name="my-cluster"

# Count by severity
source_type="prometheus_alertmanager" | count by severity

# Count by namespace
source_type="prometheus_alertmanager" | count by namespace

# Top 10 alerts
source_type="prometheus_alertmanager" | count by alertname | sort by _count desc | limit 10
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
| Alerts not reaching LM | Add explicit `namespace` label to PrometheusRule alert definitions |
| Logs not mapping to resources | Add `openshift.cluster.name` property to cluster resource and `cluster_name` label to alerts |
| Egress blocked (managed platforms) | Whitelist `*.logicmonitor.com:443` in egress firewall rules |
