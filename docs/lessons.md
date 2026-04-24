# Project-Specific Learned Behaviors

Rules learned from debugging sessions on this repository. Reviewed at session start. These are hard constraints derived from empirical evidence against the live LogicMonitor portal and ARO clusters.

## LogicMonitor Webhook LogSource

### Webhook ingestion CAN populate the Resource column — the earlier "platform limitation" conclusion was wrong

- Validated against the live portal 2026-04-24: LogSource id 26 with a single resourceMapping `openshift.cluster.name` ← `"cluster_name"` regex successfully binds webhook logs to device 444651 (where `openshift.cluster.name = rm-aro-cluster` is a custom property). Resource column populates to `rm-aro-cluster` on every firehose row. `_user.agent: "cloud-webhooks"`, `_lm.logsource_type: "webhook"` — pure webhook path, no Fluentd involvement.
- Prior sessions' failures (2026-04-21 through 2026-04-23) tested resourceMappings whose declared keys did not correspond to real custom property values on the target device (`openshift.instance.name`, `openshift.alert.name`, `a_genURL` with `^` anchor bug). Every lookup silently missed → `_resource.attributes` populated as metadata, Resource column stayed empty, and the behaviour got mis-generalized to "webhook can never bind Resource, period."
- LM's webhook resolver DOES perform device lookup by property match — it just reports zero diagnostic signal when no device matches.
- **Binding contract (webhook path):**
  1. No `SourceName` filter blocking dispatch. Leave `filters: []` empty.
  2. Use `RegexGroup` method on the mapping so only the capture group is stored.
  3. The mapping's declared `key` must be an existing custom property on the target device, AND the extracted value must equal that property's value.
  4. The target device must NOT be assigned to a non-default Log Partition (see the Log Partitions lesson below) — that intercepts the logs before they reach the default search view.
- **How to apply:** For OpenShift AlertManager integration, the canonical `openshift.cluster.name` ← `"cluster_name"\s*:\s*"([^"]+)"` mapping works out of the box when the LM-container integration has set that custom property on the cluster device. `auto.clustername` against the same cluster device works the same way. Do not waste time adding multiple mappings — one well-chosen mapping is enough. Do not reach for the Fluentd forwarder unless you specifically need pod-level Resource binding.

### LM Log Partitions on a device intercept logs from the default search view

- A device can be assigned to a non-default Log Partition in LM (under the device's Log Partitions / Settings). Once assigned, all logs bound to that device land in that partition.
- Logs in non-default partitions do NOT appear in the standard LM Logs search or a Resource's Logs tab by default. They are queryable only by scoping to that partition explicitly.
- Symptom: webhook POSTs return 202, LogSource extracts fields correctly, device binding succeeds in `_resource.attributes` — but LM Logs search returns zero rows for the cluster/device, even with broad queries like `_message ~ "alertmanager"`.
- Root cause of the illusion that "webhook can't bind Resource": during 2026-04-21 through 2026-04-23, device 444651 had an extra partition assignment that routed all webhook-ingested logs into a non-default partition. The default search view never showed them, which masqueraded as "Resource column never populates" — when in reality, the logs WERE binding, they were just filed elsewhere. Ryan discovered this on 2026-04-24 by deleting the extra partition; rows immediately started surfacing with Resource populated.
- **How to apply:** When webhook ingestion appears to silently drop despite correct LogSource + resourceMapping + matching device property, check the target device's Log Partition assignments first. Remove any non-default partition routing unless you have a documented reason to keep it. Add this check before blaming the LogSource config or concluding "platform limitation."

### `SourceName` filter with a mismatched value silently routes all logs to `default.webhook_logsource`

- The webhook URL path segment (the final segment in `/rest/api/v1/webhook/ingest/<segment>`) auto-dispatches payloads to any LogSource whose internal identity matches.
- Adding a `SourceName Equal <value>` filter requires `<value>` to exactly match the URL path segment. Case-sensitive. Any mismatch fails the filter, and the log falls through to LM's fallback LogSource with `_lm.logsource_name: "default.webhook_logsource"`.
- **Why:** Observed empirically. SMBC reference LogSource shipped with a `SourceName` filter whose value did not match typical URL conventions, causing silent drops for weeks.
- **How to apply:** Never add a `SourceName` filter to a webhook LogSource unless you have tested the exact URL path segment match. The simpler path is to leave `filters: []` empty entirely.

### `Regex` method stores the entire regex match; `RegexGroup` stores the capture group

- On resource mappings specifically, the `Regex` method (UI label "Dynamic Regex") stores the full text that matched the regex pattern, including surrounding context.
- `RegexGroup` method (UI label "Dynamic Group Regex") stores just the content of the first capture group `(...)`.
- On logFields, both methods honor capture groups correctly — only resource mappings differ.
- This affects the EXTRACTED VALUE only — it does NOT affect whether the LogSource dispatches a payload. Sutter Health's production LogSource ships with a `Regex` method mapping that has a `^` anchor (so it never matches the payload) and dispatch still works fine. Failed extractions on a resource mapping leave that mapping's slot empty in `_resource.attributes` without breaking the LogSource itself.
- **Why:** Verified directly: regex `"cluster_name"\s*:\s*"([^"]+)"` under `Regex` method stored `"cluster_name": "rm-aro-cluster"` literal; under `RegexGroup` stored `rm-aro-cluster`. Reconfirmed dispatch independence by importing Sutter's LogSource (which has both anti-patterns) and observing successful dispatch + clean field extraction on our portal.
- **How to apply:** Use `RegexGroup` for webhook LogSource extractions when you want a usable extracted value — logFields and resource mappings alike. Do not assume that `Regex` method or `^` anchor mistakes you find in an existing LogSource are causing dispatch failures; they only produce empty extracted values.

### Free-text fields need escape-aware regex

- AlertManager annotation fields (`description`, `message`, `summary`, `runbook_url`, `group_key`) can contain embedded `\"` (JSON-escaped double quotes).
- The naive pattern `"key"\s*:\s*"([^"]+)"` truncates at the first escaped quote, silently producing partial values.
- The escape-aware pattern `"key"\s*:\s*"((?:[^"\\]|\\.)*)"` handles these correctly.
- **Why:** The `FirehoseEscapedQuotes` test alert — annotation value `The condition is "firing" when value is "above threshold"` — broke the naive pattern and worked with the escape-aware one.
- **How to apply:** Any annotation field or URL-valued field MUST use the escape-aware pattern. Simple label values (alertname, severity, namespace, etc.) can use `([^"]+)`.

### Regex patterns in webhook LogSource match against the full payload text, not individual field values

- The input to every regex is the entire raw JSON payload body, not a pre-extracted field.
- The `^` anchor means "start of the payload string", which always begins with `{"receiver":...` — not `https://`.
- Regex `^https:\/\/...` never matches a webhook payload.
- Regex `https:\/\/...` without the anchor matches substrings anywhere in the payload.
- Like the Regex/RegexGroup distinction, this affects the EXTRACTED VALUE only — a never-matching regex on a resource mapping does NOT break LogSource dispatch. It just produces an empty slot in `_resource.attributes`.
- **Why:** `cluster_id` regex `^https:\/\/[^\/]*?\.apps\.([^.]+)\.` never extracted until the `^` anchor was removed. Then it correctly extracted `qmhkwy1yzd313c0d18` from the `externalURL` field. Sutter's production LogSource keeps the `^` anchor on its `a_genURL` resource mapping (so it never extracts) and dispatch still works.
- **How to apply:** Do not use `^` or `$` anchors in webhook LogSource regex patterns unless you have proven they match against the position you intend. But also do not waste time fixing anchor mistakes in resource mappings unless you actually need the extracted value — the broken extraction is silent and harmless to dispatch.

### Large LogSource edits have a 2-5 minute propagation lag

- After saving significant LogSource changes (10+ logField additions or deletions, resource mapping edits), LM's webhook ingestion continues processing with the cached old configuration for 2-5 minutes.
- During the lag, logs may appear with incomplete field extraction, or may route to `default.webhook_logsource`.
- Small single-field edits appear to propagate within 10-30 seconds.
- **Why:** Undocumented LM internal behavior. Observed across multiple sessions.
- **How to apply:** Batch all LogSource edits into a single save, then wait 5 minutes before evaluating the results. Do not iterate rapidly on webhook LogSources — each save starts a new 5-minute window.

### Custom property names are stored lowercase by LM

- Creating a custom property `a_genURL` via the API results in stored property `a_genurl` (lowercased).
- Resource mapping lookups against custom properties appear to be case-insensitive, but the lowercasing behavior is not documented and has not been independently verified end-to-end.
- **Why:** Observed when setting `a_genURL = qmhkwy1yzd313c0d18` on device 444651 via `mcp__logicmonitor__update_device_property`.
- **How to apply:** Use lowercase property names in both regex mapping keys and device properties to avoid case-sensitivity ambiguity.

### `cluster_id` extracted from console URL is the universal cluster identifier

- Every AlertManager webhook payload includes `externalURL` and per-alert `generatorURL` fields, both containing the OpenShift console hostname (e.g., `https://console-openshift-console.apps.qmhkwy1yzd313c0d18.eastus.aroapp.io/monitoring`).
- The regex `https:\/\/[^\/]*?\.apps\.([^.]+)\.` extracts the cluster DNS segment (e.g., `qmhkwy1yzd313c0d18`).
- This works regardless of whether the customer has configured `externalLabels.cluster_name` in their `user-workload-monitoring-config`.
- **Why:** Sutter Health's production payload has no `cluster_name` label — the customer has not done the externalLabels setup step. Relying on `cluster_name` excludes all such customers.
- **How to apply:** When building LMQL queries or Fluentd transformation logic, prefer `cluster_id` over `cluster_name` for customer-portable identification.

## Testing and Debugging Workflow

### Use real AlertManager traffic, not synthetic curl

- Early session iteration used synthetic curl payloads. Each synthetic test confirmed behavior for that specific shape but did not expose field-order-dependence or shape-drift in real alerts.
- Real AlertManager payloads have variable field order and conditional fields (component, pod, runbook_url, openshift_io_alert_source appear only on certain alert types).
- The firehose PrometheusRule in `manifests/test/firehose-prometheus-rule.yaml` provides 8 diverse alert shapes re-firing every 2 minutes, giving continuous real-data validation.
- **Why:** A monolithic parse regex that worked on Sutter's specific alert shape failed on the firehose's `FirehoseWithClusterName` shape because field order differed and `openshift_io_alert_source` was absent.
- **How to apply:** Validate LogSource changes against the firehose before declaring them working. Per-field regex logFields are robust to shape drift; monolithic parse commands are not.

### Do not edit and re-fire in rapid succession during LogSource debugging

- The combination of ingestion lag (2-5 minutes) and firehose cadence (2 minutes) means rapid edits produce confusing results where logs reflect an older config than the current saved state.
- **How to apply:** One edit, save, then wait a full firehose cycle (2 minutes) plus one minute buffer (so 3+ minutes minimum) before inspecting. Do not make multiple edits during a single wait window.

## LogSource and Property Governance

### Deleting and recreating a webhook LogSource changes its ID

- LogSource IDs incremented 17 → 18 → 19 → 20 → 22 → 23 → 24 across sessions as the LogSource was deleted and recreated.
- All previous IDs are no longer addressable via the API after deletion.
- **Why:** LM does not reuse LogSource IDs. Deletion is a permanent record change.
- **How to apply:** Prefer in-place edits over delete+recreate. Track the current LogSource ID in session notes when debugging.

### Webhook URL→LogSource dispatch cache survives stale and breaks under thrash

- LM appears to maintain a server-side cache mapping webhook URL path segments to LogSource IDs. The mapping is opaque — it is NOT a strict name match (Sutter's `OpenShift_AlertManager_Webhook` does not equal URL segment `openshift_alertmanager` and dispatch still works), it is not surfaced in the LogSource definition, and it is not exposed via any documented API.
- Once the mapping registers, dispatch is stable for an indefinite period.
- Rapid delete-and-recreate of the LogSource (4+ recreates in a 24-hour window during 2026-04-21/22) caused dispatch to break: payloads received HTTP 202 Accepted but logs landed in `_lm.logsource_name = "default.webhook_logsource"` instead of the new LogSource. The break persisted across multiple recreate cycles even when the new LogSource definition was structurally identical to a known-working one.
- Recovery required importing a known-working LogSource via the portal UI (Settings → LogSources → Add → Import from JSON) and then leaving it untouched for several minutes. After that, dispatch resumed for the next firehose cycle.
- **Why:** The dispatch cache invalidation logic on LM's side is not under our control. Each delete+recreate (or possibly each PUT that touches structural fields) appears to push the URL→LogSource binding into a degraded state where the dispatcher falls back to `default.webhook_logsource`. The exact trigger threshold is unknown.
- **How to apply:** Treat webhook LogSources as nearly-immutable infrastructure. Use the canonical JSON in `logsource/OpenShift_AlertManager_Webhook.json` as the import source, import once, and accept the configuration that lands. Do not delete-and-recreate to "clean up" or experiment — every recreate adds dispatch risk. If the LogSource needs structural changes (new logFields, mapping tweaks), prefer in-place PUT updates over delete+create. If you must recreate, import via the LM Exchange UI rather than the REST API and wait at least 10 minutes before declaring failure.

### Orphan device properties persist after resource mapping debugging

- Properties set on devices during debugging (`a_genurl` on device 444651) persist until explicitly removed.
- Harmless but clutters the device's property list.
- **How to apply:** Clean up debug-only custom properties at session close using `mcp__logicmonitor__update_device_property` (or via the portal UI) with a sentinel/empty value — or document their presence in session notes for later cleanup.

## Fluentd AlertManager Forwarder

### `manifests/fluentd-sidecar/` remains the pod-log-forwarding pattern, NOT the AlertManager receiver

- The sidecar ConfigMap tails `/var/log/app/*.log` from a shared volume next to an application container. Valid for app-log-to-LM forwarding.
- The AlertManager receiver use case lives in `manifests/fluentd-alertmanager-forwarder/` as a centralized Deployment + Service. Not a sidecar (AlertManager runs in the managed `openshift-user-workload-monitoring` namespace where we cannot inject sidecars).
- **Why:** Two distinct Fluentd patterns coexist in this repo. Do not confuse them. Editing the sidecar ConfigMap to receive AlertManager webhooks breaks both use cases.

### The `lm-logs` Helm chart is not extensible via values.yaml

- Investigated `logicmonitor/k8s-helm-charts` path `lm-logs/` (master branch, 2026-04-23).
- `values.yaml` (51 lines) exposes only image, resources, fluent buffer tuning, kubernetes cluster_name, volumes/mounts, nodeSelector/affinity/tolerations, imagePullSecrets, env. No `extraConfig`, `extraSources`, `extraMatch`, or `customConfigMap` key.
- `templates/configmap.yaml` (97 lines) hardcodes the entire `fluent.conf` around `@type tail /var/log/containers/*.log` → `@type lm`.
- Chart deploys a DaemonSet (`deamonset.yaml`), not a Deployment+Service HTTP receiver — wrong delivery model for an AlertManager webhook endpoint even if config injection existed.
- **Why:** Extending the chart requires forking it or layering post-render kustomize patches, both of which add more customer operational cost than just shipping a standalone Deployment. A standalone Fluentd Deployment + Service is the simpler customer integration for the device-correlated log use case.
- **How to apply:** Do not recommend customers run `helm upgrade` to layer AlertManager forwarding into the existing `lm-logs` chart — it will not work. Ship the dedicated `manifests/fluentd-alertmanager-forwarder/` stack as a parallel deployment.

### `@type lm` plugin supports bearer_token auth — reuse the existing webhook token

- The plugin source (`logicmonitor/lm-logs-fluentd`, `lib/fluent/plugin/out_lm.rb`) auto-selects bearer auth when `access_id` or `access_key` is blank and `bearer_token` is set.
- The same `lm_logs_administrator`-role Bearer token that authenticates the webhook ingest endpoint also authenticates `/rest/log/ingest`.
- **How to apply:** Customers can reuse the existing `logicmonitor-bearer-token` Secret for the Fluentd forwarder. Documented as the default in Section 15. Optional path: create a dedicated `openshift_alertmanager_fluentd` user for independent rotation.

### LM Ingest resource_mapping binding contract — `auto.*` properties, two-key match, and `_resource.type` required

- `resource_mapping {"record_field": "device_property_name"}` reads the record's `record_field`, then LM's `/rest/log/ingest` endpoint looks up a device whose `device_property_name` property has that value. The matched device's ID becomes `_lm.resourceId` on the log.
- **Critical constraint:** on this portal (lmryanmatuszewski), only `auto.*` properties resolve for ingest lookups. `system.*`, custom, and inherited properties are silently dropped (payload 202-accepted, never indexed).
- **Critical constraint #2:** a single-key lookup like `{"auto.clustername": "rm-aro-cluster"}` or `{"auto.name": "default"}` (namespace) indexes the record (attributes populate) but does NOT bind the Resource column. Binding requires a TWO-KEY match — typically `{"auto.name": "<pod-name>", "auto.namespace": "<namespace>"}` — against an existing k8s pod device.
- **Critical constraint #3:** the payload must carry `"_resource.type": "k8s"` at top level (set via the `@type lm` plugin's `resource_type` config param) for the pod-device lookup to succeed.
- **Why:** Verified by direct `/rest/log/ingest` probes against device 444651 (rm-aro-cluster). Variants tried:
  - `{"openshift.cluster.name": "rm-aro-cluster"}` → 202-accepted, NOT indexed (custom prop)
  - `{"system.hostname": "rm-aro-cluster"}` → 202-accepted, NOT indexed (system prop)
  - `{"system.deviceId": "444651"}` → 202-accepted, NOT indexed (system prop)
  - `{"auto.clustername": "rm-aro-cluster"}` → indexed, Resource column EMPTY (single-key, cluster-level device)
  - `{"auto.name": "default"}` alone → indexed, Resource column EMPTY (single-key, namespace)
  - `{"auto.name": "pod-name", "auto.namespace": "ns"}` + `_resource.type=k8s` → indexed AND Resource column BOUND to the pod device
- **How to apply:** For AlertManager alert forwarding, the Fluentd config must extract `alerts[0].labels.pod` and `alerts[0].labels.namespace` into top-level record fields, then resource_map both with `_resource.type=k8s`. Alerts without a pod label still index but will have an empty Resource column. Do NOT waste time trying to bind cluster-level logs to the cluster device (444651) — its `auto.*` properties (`auto.clustername`, `auto.createdBy`, `auto.resourceTypeCategory`) don't form a lookup key that LM ingest will resolve. The cluster device is "Management and Governance" resource_type, not "k8s", so ingest won't bind to it.

### Webhook path and ingest path both bind Resource — they resolve through different contracts

- **Webhook path** (`/rest/api/v1/webhook/ingest/<segment>`): resolver runs each LogSource resourceMapping regex against the raw JSON body, extracts a value, and looks up a device whose declared property (by key) equals that value. Any property type works (custom, `openshift.*`, `auto.*`). Single-key lookup is sufficient. Binds to the matched device regardless of its `system.devicetype`.
- **Ingest path** (`/rest/log/ingest`): resolver reads `_lm.resourceId` from the payload as a dict of property-key → property-value, matches against devices. Empirically on this portal, only `auto.*` properties resolve, and pod-device binding requires two-key `{"auto.name": "...", "auto.namespace": "..."}` + top-level `_resource.type: "k8s"`. Cluster-level devices (resource type "Management and Governance") are not ingest-resolvable.
- Granularity trade-off:
  - Webhook path binds to the cluster device — coarse, sufficient for most customers, zero new infrastructure.
  - Ingest path (via Fluentd forwarder) binds to individual pod devices — finer granularity, adds a Deployment+Service+NetworkPolicy.
- **How to apply:** Default customers to the webhook path with `openshift.cluster.name` ← `cluster_name` mapping. Reach for the Fluentd forwarder only when per-pod navigation is a requirement AND the customer's alerts carry pod labels reliably.

## MCP Server Bugs (lm-mcp on lmryanmatuszewski portal)

### `mcp__logicmonitor__create_logsource` returns HTTP 400 for all payloads

- Reproduced 2026-04-21 and 2026-04-22 against multiple definition shapes: full canonical JSON (24 fields, WEBHOOK), minimal WEBHOOK (0 fields), minimal KUBERNETES_EVENT round-trip from the MCP's own `export_logsource` output, camelCase variant, snake_case variant. Every attempt returns generic HTTP 400 "Bad request".
- The same payload submitted via direct REST `POST /santaba/rest/setting/logsources` with `X-Version: 3` header succeeds on first attempt.
- Suspected root cause: the MCP wrapper does not send `X-Version: 3` and the LM REST endpoint rejects payloads under the older default version, OR the MCP wrapper re-serializes the payload in a form the v3 endpoint rejects.
- **How to apply:** When the MCP `create_logsource` returns 400, do not iterate on the payload shape — fall back to the direct REST call:
  ```
  curl -X POST "https://<portal>.logicmonitor.com/santaba/rest/setting/logsources" \
    -H "Authorization: Bearer $LM_BEARER_TOKEN" \
    -H "Content-Type: application/json" \
    -H "X-Version: 3" \
    -d @logsource/<file>.json
  ```
- The MCP `import_logsource` is NOT a workaround — it expects LM Exchange JSON format, which is structurally different from REST API format. Our exported JSON is REST API format, so `import_logsource` rejects it with "module type does not match".

### MCP read-side tools work fine

- `get_logsource`, `get_logsources`, `export_logsource`, `delete_logsource`, `update_logsource` (untested under stress in this session but did not exhibit this bug) all functioned correctly.
- The bug is isolated to `create_logsource`.
