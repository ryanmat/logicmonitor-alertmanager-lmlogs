#!/usr/bin/env bash
# Description: Sends a test AlertManager payload directly to the LM webhook endpoint.
# Description: Bypasses AlertManager to verify the LM LogSource receives and parses correctly.
#
# Usage: ./test-webhook-curl.sh <portal_name> <bearer_token> <cluster_name>
# Example: ./test-webhook-curl.sh myportal lmb_xxxxx my-cluster

set -euo pipefail

PORTAL_NAME="${1:?Usage: $0 <portal_name> <bearer_token> <cluster_name>}"
BEARER_TOKEN="${2:?Usage: $0 <portal_name> <bearer_token> <cluster_name>}"
CLUSTER_NAME="${3:?Usage: $0 <portal_name> <bearer_token> <cluster_name>}"

WEBHOOK_URL="https://${PORTAL_NAME}.logicmonitor.com/rest/api/v1/webhook/ingest/openshift_alertmanager"

echo "Sending test alert to: ${WEBHOOK_URL}"
echo "Cluster name: ${CLUSTER_NAME}"
echo ""

RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${WEBHOOK_URL}" \
  -H "Authorization: Bearer ${BEARER_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{
    \"receiver\": \"logicmonitor-webhook\",
    \"status\": \"firing\",
    \"alerts\": [{
      \"status\": \"firing\",
      \"labels\": {
        \"alertname\": \"LogicMonitorWebhookTest\",
        \"severity\": \"warning\",
        \"namespace\": \"test\",
        \"cluster_name\": \"${CLUSTER_NAME}\"
      },
      \"annotations\": {
        \"summary\": \"Test alert from curl - verifying webhook pipeline\",
        \"description\": \"This is a manual test alert sent via curl.\",
        \"runbook_url\": \"https://runbooks.example.com/logicmonitor-webhook-test\"
      },
      \"startsAt\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
      \"endsAt\": \"0001-01-01T00:00:00Z\",
      \"generatorURL\": \"https://console-openshift-console.apps.${CLUSTER_NAME}.example.io/monitoring/graph\",
      \"fingerprint\": \"testfp-$(date +%s)\"
    }],
    \"groupLabels\": {
      \"alertname\": \"LogicMonitorWebhookTest\",
      \"namespace\": \"test\"
    },
    \"commonLabels\": {
      \"alertname\": \"LogicMonitorWebhookTest\",
      \"severity\": \"warning\",
      \"namespace\": \"test\",
      \"cluster_name\": \"${CLUSTER_NAME}\"
    },
    \"externalURL\": \"https://console-openshift-console.apps.${CLUSTER_NAME}.example.io/monitoring\",
    \"version\": \"4\",
    \"groupKey\": \"testgk-$(date +%s)\",
    \"truncatedAlerts\": 0
  }")

HTTP_CODE=$(echo "${RESPONSE}" | tail -1)
BODY=$(echo "${RESPONSE}" | head -n -1)

echo "HTTP Status: ${HTTP_CODE}"
echo "Response: ${BODY}"
echo ""

if [[ "${HTTP_CODE}" == "202" ]] || [[ "${HTTP_CODE}" == "200" ]]; then
  echo "SUCCESS: Webhook accepted the payload."
  echo ""
  echo "Verify in LM Logs with this query:"
  echo "  sourceName=\"openshift_alertmanager\" AND alertname=\"LogicMonitorWebhookTest\" AND cluster_name=\"${CLUSTER_NAME}\""
else
  echo "FAILED: Expected HTTP 200 or 202, got ${HTTP_CODE}."
  echo "Check: Bearer token, portal name, LogSource source name filter."
  exit 1
fi
