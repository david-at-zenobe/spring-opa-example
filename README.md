# spring-opa-example

A minimal Spring Boot app that offloads authorization decisions to [OPA](https://www.openpolicyagent.org/)
running as a **sidecar**, instead of writing authz logic in Java. See `SitesController` for the
call site and `opa/users/policy.rego` + `opa/users/data.json` for the policy/data being evaluated.

## What "sidecar" means here

OPA runs as its own process next to the app (here: `localhost:8181`, started by `run.sh`; in prod, a
container in the same pod). The app calls it over localhost HTTP for every decision instead of
embedding authz logic itself:

```
Client -> Spring Boot app -> OPA (localhost:8181) -> allow/deny + data
                                  ^ loaded with policy.rego + data.json
```

Policy (Rego) and reference data (users/roles/orgs/etc, as JSON) are loaded into OPA as **bundles**.
OPA evaluates decisions entirely in memory — no network call to a database per request.

## Why a sidecar vs. the alternatives

The team is evaluating this against AWS Verified Permissions (AVP) and a hand-rolled central authz
service. Rough trade-offs:

| | OPA sidecar | AWS Verified Permissions | Central authz service (custom) |
|---|---|---|---|
| **Latency** | Localhost call, in-memory eval — sub-ms | Network call to AWS per decision | Network call per decision |
| **Availability** | Fails only if the pod/sidecar dies | Coupled to AVP/AWS availability | Coupled to that service's uptime; becomes a SPOF |
| **Ops footprint** | One extra container per pod, pulling a config/bundle it already knows how to poll for | None — fully managed | You build and run everything yourself (HA, scaling, deploys) |
| **Policy language** | Rego — flexible, general-purpose, a bit more to learn | Cedar — simpler, formally verifiable, less expressive | Whatever you write — no policy/data separation by default |
| **Vendor lock-in** | None, open source | AWS only | None, but bespoke |
| **Data freshness** | As fresh as your bundle push (see below) | Data pushed into AVP's policy store — same class of problem | Whatever you build — often just a live DB query |
| **Maturity/tooling** | Widely adopted OSS, well-documented | Native AWS console/IAM integration | None — you build it |

All three are workable. AVP trades a bit of latency and flexibility for "someone else runs it," and a
custom service gives full control at the cost of building an entire policy engine yourselves. OPA
sits in the middle in a way that suits us well here: it's a single extra sidecar container (not a
fleet to operate), it keeps decisions local and fast, and it's a well-trodden pattern — Netflix and
several other large platforms run OPA as their authorization layer at far greater scale than we need.
Given our latency and dataset size, it's a reasonable default rather than a big bet.

## Data scale

Our authz dataset (users, roles, orgs, buses, sites, chargers combined) is expected to top out
around **100K entries**. OPA has been stress-tested well beyond that — 25K requests/sec against a
handful of policies, on a single core, staying under 1GB RSS. Production load is expected to be far
below that, so a single OPA instance holding the full dataset in memory is comfortably within budget.

## Data/policy distribution: short-term vs. long-term

**Short-term (what this repo does):** policy and data are just files shipped alongside the app —
`opa/users/policy.rego` + `opa/users/data.json`, loaded via `opa run <dirs>` (see `run.sh`). Simple,
zero extra infra. The catch: updating data means rebuilding/redeploying, which doesn't scale once
users/orgs/etc. change often or are owned by other systems.

**Long-term:** decouple data updates from app deploys using OPA's [bundle
API](https://www.openpolicyagent.org/docs/management-bundles/):

- Source of truth (users, roles, orgs, buses, sites, chargers) is published to a **Kafka topic,
  compacted** by key — so the topic always holds the latest state per entity, not a full history.
- A build process consumes that compacted topic, materializes it into an OPA bundle (data.json +
  policy), and publishes it to a bundle server (e.g. S3 + OPA's bundle HTTP API).
- Each OPA sidecar polls the bundle server on an interval and hot-reloads — no app redeploy, no
  restart, and every sidecar converges on the same data within one poll interval.

This keeps the sidecar's fast in-memory evaluation while letting data owners push updates
independently of app release cycles.

## Kubernetes: OPA as a sidecar

Same pattern as `run.sh`, but as a second container in the app's pod instead of a second local
process. The app keeps calling `http://localhost:8181` — nothing changes there.

This is the **short-term** setup: it mounts this repo's `opa/` directory (as-is — same
`policy.rego` / `data.json` files `run.sh` loads locally) into the OPA container via a ConfigMap, so
there's no bundle infra to stand up yet.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sites-app
spec:
  replicas: 2
  selector:
    matchLabels: { app: sites-app }
  template:
    metadata:
      labels: { app: sites-app }
    spec:
      containers:
        - name: app
          image: registry.example.com/sites-app:latest
          ports:
            - containerPort: 8080
          # Talks to OPA over localhost — same pod, no service needed.

        - name: opa
          image: openpolicyagent/opa:latest
          args:
            - "run"
            - "--server"
            - "--addr=localhost:8181"
            - "-c=/config/opa-config.yaml"
            - "/bundles/initialised"
            - "/bundles/users"
          ports:
            - containerPort: 8181
          volumeMounts:
            - { name: opa-config, mountPath: /config }
            - { name: opa-bundles, mountPath: /bundles/initialised/data.json, subPath: initialised-data.json }
            - { name: opa-bundles, mountPath: /bundles/users/data.json, subPath: users-data.json }
            - { name: opa-bundles, mountPath: /bundles/users/policy.rego, subPath: users-policy.rego }
          readinessProbe:
            httpGet: { path: /health, port: 8181 }
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits: { cpu: 500m, memory: 512Mi } # generous vs. the ~1GB @ 25K req/s benchmark

      volumes:
        - name: opa-config
          configMap: { name: opa-config }
        - name: opa-bundles
          configMap: { name: opa-bundles } # contents of opa/ in this repo, one key per file
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: opa-config
data:
  # In the future: point OPA at S3 instead of baking data.json into the image (see below).
  # services:
  #   s3:
  #     url: https://<bucket>.s3.<region>.amazonaws.com
  #     credentials:
  #       s3_signing:
  #         environment_credentials: {} # picked up from the pod's IRSA role
  # bundles:
  #   authz:
  #     service: s3
  #     resource: bundles/authz.tar.gz
  #     polling:
  #       min_delay_seconds: 30
  #       max_delay_seconds: 60
  opa-config.yaml: |
    decision_logs:
      console: true
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: opa-bundles
data:
  initialised-data.json: |
    {
      "initialised": true
    }
  users-data.json: |
    {
      "users": {
        "revision": "1",
        "entries": {
          "alice": { "org": "acme-corp" },
          "bob": { "org": "globex" }
        }
      }
    }
  users-policy.rego: |
    package com.zenobe.authz.users

    import rego.v1

    initialised := data.initialised

    revision := data.users.revision

    user := data.users.entries[input.user]

    result := {"org": user.org}

    response := {
    	"initialised": initialised,
    	"revision": revision,
    	"result": result,
    }
```

**In the future**, once data volume/update frequency outgrows "edit a ConfigMap and roll the pod":
swap the `opa-bundles` ConfigMap and static `args` for the commented-out `services`/`bundles` block
in `opa-config.yaml`, pointing at an S3 bucket that the Kafka-fed build process (described above)
publishes `bundles/authz.tar.gz` to. OPA then polls S3 every 30-60s and hot-reloads on its own — no
ConfigMap edits, no rollout, and the `/bundles/initialised /bundles/users` directory args (plus the
`opa-bundles` volume mounts) in `opa run` go away entirely since the bundle already contains everything.

## Running the demo

```
./run.sh
```

Starts OPA (`:8181`) and the Spring Boot app (`:8080`), then exercises `/sites?user=alice` and
`/sites?user=bob` (known users) and `/sites?user=carol` (unknown -> 403, fail-closed).
