# DevOps troubleshooting assignment

Resolve three incidents in a Go API running on a single-node k3d cluster with Postgres, Helm, and ingress-nginx.

## Prerequisites

- Docker, k3d, kubectl, and Helm.
- At least 4 CPUs, 6 GB RAM, and 15 GB free disk for Docker.
- Tested with Docker 28.4, k3d 5.9.0 (k3s v1.35.5), kubectl 1.35, and Helm 4.3.0.

## Setup

```sh
make up
```

Creates `inference-lab`, switches kubectl to `k3d-inference-lab`, and installs chart 1.0.0 in namespace `inference` with three API replicas. Setup takes approximately 4–5 minutes.

```sh
curl -i -H 'Host: inference.local' http://localhost:18080/v1/generate
```

For a different cluster name or port, use `make up CLUSTER=my-lab HTTP_PORT=28080` and pass the same overrides to subsequent commands.

## Repository

- `app/`: API source; listens on port 8080. `/healthz` checks process health, `/readyz` checks database connectivity, and `/v1/generate` stores a generation and returns JSON with `X-RateLimit-Limit`. Requests can take up to 15 seconds.
- `chart/inference-api/`: chart 1.1.0 to deploy.
- `releases/inference-api-1.0.0.tgz`: initial release chart.
- `deploy/`: Postgres and ingress-nginx manifests.
- `scripts/`: traffic generation and incident verification.

## Incidents

### 1. Public endpoint unavailable

After default-deny NetworkPolicies were introduced, public requests fail and the app logs database hostname resolution errors. Restore access while allowing only ingress-controller traffic into the app and necessary outbound dependencies.

### 2. Upgrade and configuration failures

The upgrade from chart 1.0.0 to 1.1.0 fails. A forced upgrade in staging still advertises the old rate limit. Deploy the repository chart with the configured limit, and ensure future configuration changes reach running pods without manual restarts.

### 3. Errors during deployments

Rolling deployments cause 502/503 errors. Deployments must complete without failed requests under the provided load test or available replicas falling below the configured count.

## Commands

| Command | Purpose |
|---|---|
| `make loadtest` | Generate traffic; defaults to 30 seconds and 30 concurrent workers. |
| `make upgrade` | Upgrade to the repository chart while generating traffic. |
| `make verify` | Check all three incidents; use `INCIDENTS=2` to check one. |
| `make down` | Delete the lab cluster. |

Verification creates temporary `verify-*` namespaces. The deployment check takes approximately 2–3 minutes.

## Rules

- Fix root causes in the chart and cluster configuration only.
- Do not modify `app/`, `Makefile`, or `scripts/`.
- Default-deny policies must remain in place; ingress retries must remain disabled. Generations are billed per call and are not idempotent.
- Official Kubernetes, Helm, and ingress-nginx documentation is allowed; AI tools are not.
- Be prepared to explain your changes and validation.
