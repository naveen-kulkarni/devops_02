# inference-api platform

Local copy of the inference API stack. It runs on a single-node k3d cluster and is close enough to staging to reproduce the open incidents below.

## Components

- `app/` - Go service behind the public API. It listens on 8080 and exposes:
  - `GET /healthz` - process is up
  - `GET /readyz` - database is reachable
  - `GET /v1/generate` - runs a generation, stores it in Postgres and returns JSON. Most generations take 50-150ms; some take up to 15s. The response carries `X-RateLimit-Limit`.
- `chart/inference-api/` - Helm chart for the service (version 1.1.0, not yet rolled out).
- `releases/inference-api-1.0.0.tgz` - the chart version currently deployed.
- `deploy/postgres.yaml` - single-replica Postgres in the same namespace.
- `deploy/ingress-nginx.yaml` - ingress-nginx controller. Retries to upstreams are disabled at the controller because generations are billed per call and are not idempotent.
- `scripts/` - load test and incident checks.

The app is owned by another team. Fix incidents in the chart and cluster configuration only; do not modify app/.

## Prerequisites

Tested with:

- Docker 28.4 (Colima, 4 CPUs, 8 GB memory)
- k3d 5.9.0 (k3s v1.35.5)
- kubectl 1.35
- helm 4.3.0

Docker needs at least 4 CPUs, 6 GB of memory and 15 GB of free disk.

## Setup

```
make up
```

This creates the cluster `inference-lab` and installs ingress-nginx. It builds and imports the app image, deploys Postgres, and installs release `inference-api` from `releases/inference-api-1.0.0.tgz` into namespace `inference` with 3 replicas. It takes 4-5 minutes on a laptop and switches your kubectl context to `k3d-inference-lab`.

The ingress is exposed on `localhost:18080`. If the port or cluster name is taken:

```
make up CLUSTER=my-lab HTTP_PORT=28080
```

Pass the same variables to every other make target.

Calling the API:

```
curl -i -H 'Host: inference.local' http://localhost:18080/v1/generate
```

Rebuilding the app image is not needed for any of the incidents. `make image` does it if you want to.

## Commands

- `make loadtest` - steady traffic through the ingress (`DURATION=30`, `CONCURRENCY=30`). It prints total requests and non-2xx responses.
- `make upgrade` - runs `helm upgrade` of the release to `./chart/inference-api` while a load test runs, and prints the error count. This is what the deploy pipeline does.
- `make verify` - checks all three incidents and prints PASS/FAIL for each. `make verify INCIDENTS=2` checks one. Incidents 1 and 3 deploy throwaway copies of the chart into `verify-*` namespaces; incident 3 takes about 2-3 minutes.
- `make down` - deletes the cluster.

## Incidents

### 1. Public endpoint down after network policy rollout

Reported by: Security / on-call

After the security team merged the default-deny NetworkPolicies into the chart, every request to the public endpoint fails with 502. The app logs show it cannot resolve the database hostname. Security requires default-deny to stay in place: nothing outside the ingress controller may reach the app, and the app must not be able to reach anything other than what it needs.

### 2. Chart 1.1.0 upgrade fails and config changes do not apply

Reported by: Platform team

Upgrading the `inference-api` release from chart 1.0.0 to 1.1.0 fails. When someone forced it through on staging, the new rate limit configured for 1.1.0 had no effect and responses still advertise the old limit. We also need config changes to reach running pods on future upgrades without someone restarting them by hand. The live release has to end up on the chart in this repo.

### 3. Errors during every deploy

Reported by: Customer support / Product

Every deploy causes a burst of 502/503 errors for customers, even though the Deployment uses rolling updates. Product wants zero failed requests during deploys, and we can't drop below the configured number of replicas while a deploy is in progress.

## Rules

- Fix root causes, not symptoms.
- app/ is off-limits. Do not modify the Makefile or anything under scripts/.
- Default-deny must remain in place, and ingress retries stay disabled.
- Official Kubernetes, Helm and ingress-nginx documentation may be used. AI tools may not.
- Be ready to explain every change you make.
