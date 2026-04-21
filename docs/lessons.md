# Project-Specific Learned Behaviors

Rules learned from debugging sessions on this repository. Reviewed at session start. These are hard constraints derived from empirical evidence against the live LogicMonitor portal and ARO clusters.

## LogicMonitor Webhook LogSource

### Webhook ingestion does not populate the Resource or Resource Type columns

- Tested every permutation of `Regex`, `RegexGroup`, and `WebhookAttribute` methods on resource mappings.
- Tested with and without custom properties (`openshift.cluster.name`, `a_genURL`, `system.displayname`, `auto.clustername`) set on matching devices.
- Tested against real AlertManager traffic from an ARO cluster, not synthetic curl alone.
- Confirmed Sutter Health's production portal exhibits the same behavior — they have not solved it either.
- **Why:** Platform behavior of LM's webhook ingestion pipeline. Undocumented in LM's public docs.
- **How to apply:** Do not invest more time trying to make webhook resource mapping populate the Resource column. For per-device log-to-alert correlation in the LM UI, pivot to collector-based ingestion (Fluentd sidecar forwarder to `/rest/log/ingest` with explicit `_lm.resourceId`).

### `SourceName` filter with a mismatched value silently routes all logs to `default.webhook_logsource`

- The webhook URL path segment (the final segment in `/rest/api/v1/webhook/ingest/<segment>`) auto-dispatches payloads to any LogSource whose internal identity matches.
- Adding a `SourceName Equal <value>` filter requires `<value>` to exactly match the URL path segment. Case-sensitive. Any mismatch fails the filter, and the log falls through to LM's fallback LogSource with `_lm.logsource_name: "default.webhook_logsource"`.
- **Why:** Observed empirically. SMBC reference LogSource shipped with a `SourceName` filter whose value did not match typical URL conventions, causing silent drops for weeks.
- **How to apply:** Never add a `SourceName` filter to a webhook LogSource unless you have tested the exact URL path segment match. The simpler path is to leave `filters: []` empty entirely.

### `Regex` method stores the entire regex match; `RegexGroup` stores the capture group

- On resource mappings specifically, the `Regex` method (UI label "Dynamic Regex") stores the full text that matched the regex pattern, including surrounding context.
- `RegexGroup` method (UI label "Dynamic Group Regex") stores just the content of the first capture group `(...)`.
- On logFields, both methods honor capture groups correctly — only resource mappings differ.
- **Why:** Verified directly: regex `"cluster_name"\s*:\s*"([^"]+)"` under `Regex` method stored `"cluster_name": "rm-aro-cluster"` literal; under `RegexGroup` stored `rm-aro-cluster`.
- **How to apply:** Always use `RegexGroup` for webhook LogSource extractions — logFields and resource mappings alike. The `Regex` method produces unusable output for device-property lookups.

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
- **Why:** `cluster_id` regex `^https:\/\/[^\/]*?\.apps\.([^.]+)\.` never extracted until the `^` anchor was removed. Then it correctly extracted `qmhkwy1yzd313c0d18` from the `externalURL` field.
- **How to apply:** Do not use `^` or `$` anchors in webhook LogSource regex patterns unless you have proven they match against the position you intend.

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

- LogSource IDs incremented 17 → 18 → 19 → 20 during this session as the LogSource was deleted and recreated.
- All three previous IDs are no longer addressable via the API after deletion.
- **Why:** LM does not reuse LogSource IDs. Deletion is a permanent record change.
- **How to apply:** Prefer in-place edits over delete+recreate. Track the current LogSource ID in session notes when debugging.

### Orphan device properties persist after resource mapping debugging

- Properties set on devices during debugging (`a_genurl` on device 444651) persist until explicitly removed.
- Harmless but clutters the device's property list.
- **How to apply:** Clean up debug-only custom properties at session close using `mcp__logicmonitor__update_device_property` (or via the portal UI) with a sentinel/empty value — or document their presence in session notes for later cleanup.

## Fluentd Sidecar Forwarder (Planned)

### Existing `manifests/fluentd-sidecar/` is for a different use case

- The current ConfigMap defines a Fluentd configuration that tails `/var/log/app/*.log` — a pod-log-forwarding sidecar pattern.
- It is not an AlertManager webhook receiver.
- The `@type lm` output plugin + `resource_mapping` config is the right primitive — `{"cluster_name": "openshift.cluster.name"}` in that block does populate the Resource column via the LM Ingest API.
- **Why:** Confirmed by reading the ConfigMap contents and tracing the data flow. `@type lm` uses `/rest/log/ingest` with explicit `_lm.resourceId`, which is the documented path that populates Resource correctly.
- **How to apply:** Rework the ConfigMap for AlertManager webhook ingestion: `<source>` becomes `@type http` on port 9880, filter transforms the AlertManager JSON into a flat record with `cluster_name` injected from an ENV var (cluster identity known at deploy time, not parsed from payload), output stays `@type lm`. Deploy as a Deployment + Service (not a sidecar) because AlertManager is in a managed namespace where we cannot inject sidecars.
