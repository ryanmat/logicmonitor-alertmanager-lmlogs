# logicmonitor-alertmanager-lmlogs

## Project Names
- Claude: TurboGecko
- Ryan: ChadThunder

## What This Is
Kubernetes manifests and docs for forwarding Prometheus AlertManager alerts into LogicMonitor LM Logs via webhook. Not a software application -- no code to build or test. Deliverable is YAML manifests and customer-facing documentation.

## Repo Structure
- `manifests/base/` - Kustomize base (AlertmanagerConfig, Secret)
- `manifests/overlays/<cluster>/` - Per-cluster Kustomize patches
- `manifests/test/` - Test PrometheusRule and curl verification script
- `docs/` - Customer-facing documentation (integration guide, ARO considerations)

## Conventions
- Kubernetes manifests use AlertmanagerConfig `monitoring.coreos.com/v1beta1`
- All YAML files start with 2-line Description comments
- Bearer tokens never committed to git -- placeholder values only
- LogSource source name: `openshift_alertmanager`

## LM Portal Configuration
- LogSource: `OpenShift_AlertManager_Webhook`
- Webhook endpoint: `https://<portal>.logicmonitor.com/rest/api/v1/webhook/ingest/openshift_alertmanager`
- Resource mapping key: `openshift.cluster.name`
