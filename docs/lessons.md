# Project-Specific Learned Behaviors

Rules learned from debugging sessions on this repository. Reviewed at session start. These are hard constraints derived from empirical evidence against the live LogicMonitor portal and ARO clusters.

## LogicMonitor Webhook LogSource

### Webhook ingestion does not populate the Resource or Resource Type columns

- Tested every permutation of `Regex`, `RegexGroup`, and `WebhookAttribute` methods on resource mappings.
- Tested with and without custom properties (`openshift.cluster.name`, `a_genURL`, `system.displayname`, `auto.clustername`) set on matching devices.
- Tested against real AlertManager traffic from an ARO cluster, not synthetic curl alone.
- Reconfirmed by importing Sutter Health's exact production LogSource into our portal: `_resource.attributes` populates with the extracted attribute keys, but the Resource column itself stays empty even when device properties match the extracted values exactly.
- The `_resource.attributes` array is metadata extraction output, not a device binding. Resource column binding requires a separate mechanism that webhook ingestion does not provide.
- **Why:** Platform behavior of LM's webhook ingestion pipeline. Undocumented in LM's public docs. The only path that populates the Resource column is collector-based ingestion via `/rest/log/ingest` with an explicit `_lm.resourceId` in the payload.
- **How to apply:** Do not invest more time trying to make webhook resource mapping populate the Resource column. For per-device log-to-alert correlation in the LM UI, pivot to collector-based ingestion (Fluentd forwarder to `/rest/log/ingest` with explicit `_lm.resourceId` resolved via the `@type lm` output plugin's `resource_mapping` config).

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

### `resource_mapping` binds logs to a device by matching a device property

- `resource_mapping {"record_field": "device_property_name"}` reads the record's `record_field`, then LM's `/rest/log/ingest` endpoint looks up a device whose `device_property_name` property has that value. The matched device's ID becomes `_lm.resourceId` on the log.
- For OpenShift cluster logs: `{"cluster_name": "openshift.cluster.name"}` where `cluster_name` is injected into the record via Fluentd's `record_transformer` from the `CLUSTER_NAME` pod env.
- **Why:** This is the ONLY documented mechanism that populates the Resource column in LM Logs. Webhook ingestion has no equivalent resolution step — its `resource_mapping` only stores attribute metadata, never binds to a device.
- **How to apply:** Any LogSource-style customer onboarding that claims device-correlated logs must route through `/rest/log/ingest`. Webhook ingestion is only sufficient when Resource column correlation is not needed.

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
