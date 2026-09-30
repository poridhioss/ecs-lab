# Lab Plan (Full-Fledged): Build a Multi-Tenant Agent Cloud

**Course:** Build Your Own ECS: Multi-Tenant Container Orchestration (Python track)
**Final exam target:** Multi-Tenant Agent Cloud with SSO and Centralized Logging
**Total labs:** 15 core + 1 optional
**Estimated student time:** ~35–45 hours total
**Audience:** Students / event participants
**Prerequisites:** Linux CLI, Python, Docker basics, basic HTTP/REST

---

## Philosophy of this plan

One concept per lab. Each lab introduces a single new idea, gets it working, and verifies it before the next lab builds on it. This gives students more checkpoints, makes debugging easier, and lets each lab document stay focused. It also goes deeper than the exam strictly requires in two places (a real best-fit scheduler and an explicit isolation test lab), because those are where students usually build real understanding.

---

## Platform constraints (Poridhi)

This plan is reference material; the bare-minimum plan is the one being built. If any lab from here is pulled in, apply the same platform rules the bare-minimum plan uses (details in `PORIDHI_PLATFORM.md`):

- Every lab launch is a fresh workspace with fresh AWS credentials, so every lab after the first needs a scripted **catch-up** (fresh credentials → `git checkout lab-NN-start` → `terraform apply` → `scripts/catchup.sh` → verify) and ends with `terraform destroy`.
- Only `t2.micro` and `t3.medium` are confirmed allowed instance types. Use a split layout of `t3.medium`s: `control-01` (control plane, Postgres, Temporal, Redis, Prometheus, Grafana), `obs-01` (Elasticsearch, Kibana), `auth-01` (Authentik), `node-01`/`node-02` (agents). Provision only the machines each lab needs.
- Student-facing titles carry no lab numbers; cross-reference labs by bold title.
- Authentik must be configured by script, with issuer and redirect URIs templated from the session's public IPs.
- Web UIs are reached via EC2 public IP + opened port (to be verified).
- Suggested ordering if expanded: Foundation → Networking → Compute → Observability → Identity → Experience, so Authentik only appears in the last few catch-ups.

## Reference environment

| Machine | Role | Size | Runs |
|---|---|---|---|
| `control-01` | Control plane | t3.medium | FastAPI control plane, Postgres, Temporal, Redis, Prometheus, Grafana |
| `obs-01` | Logging | t3.medium | Elasticsearch, Kibana |
| `auth-01` | Identity | t3.medium | Authentik |
| `node-01`, `node-02` | Compute nodes | t3.medium | Agent, Docker, Fluent Bit, Node Exporter |

**Tenants used throughout:** `alpha` (VXLAN ID 100, subnet `10.10.1.0/24`) and `beta` (VXLAN ID 200, subnet `10.10.2.0/24`).

**Suggested reference repo layout:**

```
agent-cloud/
├── control-plane/     # FastAPI app, workflows, scheduler, auth, SSE
├── agent/             # registration, heartbeat, network, activities, metrics, log publisher
├── infra/             # docker-compose files, prometheus.yml, fluent-bit.conf, systemd units
├── web-ui/            # tenant dashboard
├── tests/             # isolation and end-to-end tests
└── docs/              # lab documents
```

---

## Lab list at a glance

| # | Lab | Phase | Exam section |
|---|---|---|---|
| 01 | Bootstrap the Control Plane | Foundation | — |
| 02 | Agent Bootstrapping and Registration | Foundation | 2 |
| 03 | Heartbeats, Capacity, and Node Health | Foundation | 2 |
| 04 | Tenant Network Allocation | Networking | 2, 3 |
| 05 | VXLAN Bridges Across Nodes | Networking | 2, 3 |
| 06 | Launch Containers on Tenant Bridges | Compute | 3 |
| 07 | Container Lifecycle Workflows with Temporal | Compute | 5 |
| 08 | Best-Fit Scheduler | Compute | 3 |
| 09 | Deploy Authentik and Define Tenants | Identity | 1 |
| 10 | Protect APIs with JWT and Tenant Authorization | Identity | 1 |
| 11 | Centralized Logging with Fluent Bit + Elasticsearch + Kibana | Observability | 4 |
| 12 | Metrics with Prometheus + Grafana | Observability | 6 |
| 13 | Real-Time Log Streaming with Redis + SSE | Experience | 8 |
| 14 | Tenant Web UI | Experience | 7 |
| 15 | Capstone: Isolation Tests and End-to-End Demo | Integration | All |
| 16 | *(Optional)* Service Discovery with Route 53 | Bonus | — |

---

## Phase 1 — Foundation

### Lab 01 — Bootstrap the Control Plane

**Goal:**
Stand up the central brain of the system: the database that holds state and the workflow engine that will orchestrate container operations.

**What you will build:**
- `control-01` with Postgres, Temporal, and Temporal UI via Docker Compose
- An empty FastAPI control plane with a `/health` endpoint

**Steps:**
1. Launch `control-01` and install Docker + Docker Compose.
2. Write a `docker-compose.yml` for Postgres, Temporal server, and Temporal UI.
3. Create the FastAPI app skeleton with a database connection and `/health`.
4. Open an SSH tunnel and load Temporal UI at `http://localhost:8233`.

**Expected output:**
- `docker ps` shows Postgres, Temporal, Temporal UI running
- `curl localhost:8000/health` returns OK, including database connectivity
- Temporal UI loads

**Reference solution should include:** compose file, FastAPI skeleton, DB connection module.

---

### Lab 02 — Agent Bootstrapping and Registration

**Goal:**
Introduce the agent: a small Python program on each compute node that represents that node to the control plane. On startup, it registers itself so the control plane knows the node exists.

**What you will build:**
- An `agents` registry table in Postgres
- `POST /agents/register` and `GET /agents` on the control plane
- `agent.py` that collects node info (hostname, IP, total CPU, total memory) and registers
- A systemd unit so the agent starts on boot

**Steps:**
1. Launch `node-01` and `node-02`, install Docker and Python.
2. Implement the registry endpoints and table.
3. Write the agent's startup routine using `psutil`.
4. Protect agent endpoints with a shared agent token (agents are machines, not users).
5. Install the agent as a systemd service on both nodes and reboot one node to confirm it re-registers.

**Expected output:**
- `GET /agents` lists both nodes with their IP and capacity
- After reboot, the node re-registers automatically

**Reference solution should include:** `agent/agent.py`, `agent.service`, registry schema, sequence diagram matching the exam's registration flow.

---

### Lab 03 — Heartbeats, Capacity, and Node Health

**Goal:**
Registration only says "I exist." Heartbeats say "I'm still alive, and here's what I have free right now." This is what the scheduler will rely on later.

**What you will build:**
- `POST /agents/{node_id}/heartbeat` with `cpu_free`, `mem_free`, `container_count`
- A heartbeat loop in the agent every 10 seconds
- A control plane background task marking agents `offline` after 30 seconds of silence

**Steps:**
1. Add the heartbeat endpoint and store latest capacity on the agent row.
2. Add the heartbeat loop to the agent.
3. Add the offline checker.
4. Stop the agent on `node-02`, confirm it goes `offline`, restart it, confirm it returns `online`.
5. Run `stress` on `node-01` and confirm reported free CPU drops.

**Expected output:**
- `GET /agents` shows live capacity and `last_seen` timestamps
- Status transitions `online` → `offline` → `online` work correctly

**Reference solution should include:** heartbeat code, offline checker, explanation of timeout choices.

---

## Phase 2 — Networking

### Lab 04 — Tenant Network Allocation

**Goal:**
Give each tenant its own network identity: a VXLAN ID and a subnet, owned only by that tenant. This lab is only the bookkeeping; the next lab makes it real on the nodes.

**What you will build:**
- A `tenants` table: `tenant_id`, `vxlan_id`, `subnet`
- `POST /tenants/{tenant_id}/network` that allocates the next free VXLAN ID and `/24`
- Simple IP address management (IPAM): a table tracking which IPs in each subnet are in use, plus a node-specific range per tenant

**Steps:**
1. Implement allocation logic that is idempotent (calling twice returns the same result).
2. Divide each tenant subnet into per-node ranges (e.g. `.10–.99` for `node-01`, `.110–.199` for `node-02`) so nodes never hand out the same IP.
3. Implement `allocate_ip(tenant_id, node_id)` and `release_ip(...)`.

**Expected output:**
- `alpha` gets VXLAN 100 / `10.10.1.0/24`, `beta` gets VXLAN 200 / `10.10.2.0/24`
- Repeated calls return the same allocation
- IP allocation never returns a duplicate

**Reference solution should include:** schema, allocation functions, unit tests for IPAM.

---

### Lab 05 — VXLAN Bridges Across Nodes

**Goal:**
Turn the tenant's network from a database row into a real virtual network stretching across both nodes. Containers of the same tenant on different machines should behave as if they share one switch.

**What you will build:**
- Agent function `setup_tenant_network(tenant_id, vxlan_id, subnet, peers)`
- Per tenant, per node: a Docker bridge network (`br-alpha`), a VXLAN interface (`vxlan100`), and forwarding entries to each peer node
- Control plane logic that runs this on every online agent when a tenant network is created

**Steps:**
1. Create the tenant Docker network with a fixed bridge name, the tenant subnet, the node's IP range, and a node-specific gateway.
2. Create the VXLAN interface: `ip link add vxlan100 type vxlan id 100 dstport 4789 dev eth0 nolearning`
3. Add forwarding entries for peers: `bridge fdb append 00:00:00:00:00:00 dev vxlan100 dst <peer_ip>`
4. Attach `vxlan100` to `br-alpha`, bring everything up.
5. Make the function idempotent so re-running it does not fail.
6. Run a test container per node on `alpha`, ping across nodes.

**Expected output:**
- `ip link show` shows the VXLAN interfaces and bridges on both nodes
- Cross-node ping between `alpha` containers succeeds

**Reference solution should include:** `agent/network.py`, a diagram of bridge + VXLAN + eth0 on each node, pitfalls section (UDP 4789 in security groups, MTU, duplicate gateways).

---

## Phase 3 — Compute

### Lab 06 — Launch Containers on Tenant Bridges

**Goal:**
Launch a tenant's container on a chosen node, attached to that tenant's network with an IP from IPAM, and labeled so the rest of the system knows who owns it.

**What you will build:**
- A Temporal worker inside the agent, listening on a node-specific task queue
- Activities `launch_container` and `stop_container` using the Docker SDK
- `POST /containers` on the control plane (`tenant_id`, `image`, `node_id`) for now with manual node choice
- A `containers` table

**Steps:**
1. Add the Temporal worker to the agent.
2. Implement `launch_container`: attach to tenant network, set static IP, set CPU/memory limits, add labels `tenant_id`, `node_id`.
3. Implement `stop_container`: stop, remove, release IP.
4. From the control plane, dispatch the activity to the correct node's task queue via a small workflow.

**Expected output:**
- `docker ps` on the chosen node shows the container with the expected IP and labels
- `containers` table reflects the container and its status

**Reference solution should include:** `agent/activities.py`, `control-plane/containers.py`, the minimal launch workflow.

---

### Lab 07 — Container Lifecycle Workflows with Temporal

**Goal:**
Launching is only the beginning. Build a durable workflow that watches each container for its whole life, handles failure, and cleans up when its TTL expires, even if the control plane restarts mid-way.

**What you will build:**
- Activity `check_container` (running? exit code? restart count?)
- `ContainerLifecycleWorkflow`: launch → periodic health checks → terminate on failure or TTL
- A `stop` signal so users can stop a container on demand

**Steps:**
1. Implement `check_container`.
2. Write the workflow: launch, then loop with workflow timers (e.g. every 15s) calling `check_container`.
3. Terminate after N consecutive failed checks or when TTL is reached; update status to `failed` or `expired`.
4. Add a workflow signal `stop_requested` handled by the loop.
5. Use `continue_as_new` periodically so long-running workflows don't grow unbounded history.
6. Test: restart the control plane mid-lifecycle and confirm the workflow continues.

**Expected output:**
- Temporal UI shows the full lifecycle per container
- TTL expiry, failure detection, and manual stop all work
- Workflows survive a control plane restart

**Reference solution should include:** `control-plane/workflows.py`, an explanation of durable timers and why this logic belongs in Temporal rather than a cron job.

---

### Lab 08 — Best-Fit Scheduler

**Goal:**
Stop picking nodes manually. The control plane chooses the best node for each container based on the live capacity agents report.

**What you will build:**
- `schedule(cpu_req, mem_req)` using heartbeat capacity from the registry
- Best-fit logic: among nodes that fit, pick the one with the least leftover capacity
- Integration into `POST /containers` (node becomes optional)

**Steps:**
1. Filter online agents that satisfy the request.
2. Score by leftover capacity after placement, pick the minimum.
3. Account for containers launched since the last heartbeat (reserve capacity at scheduling time).
4. Return a clear error when nothing fits.
5. Compare against a "least loaded" strategy and discuss trade-offs (packing vs. spreading).

**Expected output:**
- Scheduler picks predictable nodes for a scripted sequence of requests
- Stressed or full nodes are avoided
- Requests that cannot fit return a `409` with a useful message

**Reference solution should include:** `control-plane/scheduler.py`, unit tests with fixed capacity fixtures.

---

## Phase 4 — Identity

### Lab 09 — Deploy Authentik and Define Tenants

**Goal:**
Set up the identity provider. Tenants become groups in Authentik, and users belong to exactly one tenant group.

**What you will build:**
- Authentik via Docker Compose on `auth-01`
- Groups `tenant-alpha`, `tenant-beta` and test users
- An OAuth2/OpenID provider (RS256) and application for the platform, with the `groups` claim in tokens

**Steps:**
1. Deploy Authentik and complete initial admin setup.
2. Create groups and users.
3. Create the provider and application; note the issuer URL and JWKS URL.
4. Obtain a token for a test user and decode it to confirm the `groups` claim.

**Expected output:**
- Users can log in to Authentik
- Decoded token shows issuer, expiry, and the user's tenant group

**Reference solution should include:** step-by-step configuration with screenshots, a token-fetch script.

---

### Lab 10 — Protect APIs with JWT and Tenant Authorization

**Goal:**
Make the control plane trust nothing it has not verified. Every user request carries a token, and the tenant is taken from the token, never from the request body.

**What you will build:**
- `auth.py`: JWT verification against Authentik JWKS (signature, issuer, audience, expiry), with key caching
- A `current_tenant` FastAPI dependency
- Tenant-scoped queries on all container endpoints

**Steps:**
1. Implement verification and the dependency.
2. Refactor `/containers` endpoints to use `current_tenant`.
3. Return `401` for missing or invalid tokens, `403` for cross-tenant access.
4. Keep agent endpoints on the agent token.
5. Write tests for each case.

**Expected output:**
- No token → `401`; expired token → `401`
- Alice cannot list, stop, or view `beta` containers → `403`

**Reference solution should include:** `control-plane/auth.py`, test cases for each authorization rule.

---

## Phase 5 — Observability

### Lab 11 — Centralized Logging with Fluent Bit + Elasticsearch + Kibana

**Goal:**
Collect logs from every container on every node into one searchable store, tagged with tenant, container, and node.

**What you will build:**
- Elasticsearch (single node) and Kibana on `obs-01`
- Fluent Bit on each compute node
- Containers using Docker's `fluentd` log driver to send to local Fluent Bit
- Per-tenant Kibana saved searches and dashboards

**Steps:**
1. Deploy Elasticsearch and Kibana.
2. Update `launch_container` to use the `fluentd` log driver and pass `tenant_id` through labels.
3. Configure Fluent Bit: `forward` input, add `node_id`, output to Elasticsearch.
4. Choose an index strategy (one index with a `tenant_id` field, or one index per tenant) and justify it.
5. Build one Kibana dashboard per tenant: log volume over time, recent log lines.

**Expected output:**
- Every log document has `tenant_id`, `container_id`, `node_id`, timestamp, and message
- Per-tenant dashboards show only that tenant's logs

**Reference solution should include:** `infra/fluent-bit.conf`, sample document, index mapping, dashboard export.

---

### Lab 12 — Metrics with Prometheus + Grafana

**Goal:**
Expose what each node and tenant is doing as numbers over time, and visualize it.

**What you will build:**
- Agent `/metrics`: free CPU, free memory, active containers per tenant, launches and failures counters
- Node Exporter on each node
- Prometheus scraping both, Grafana dashboards on top

**Steps:**
1. Add metrics with `prometheus_client`.
2. Run Node Exporter.
3. Configure Prometheus scrape jobs.
4. Build a Grafana dashboard: node resources, containers per tenant, failure rate.
5. Add one alert rule (e.g. agent down for 1 minute).

**Expected output:**
- All Prometheus targets `UP`
- Grafana panels react when containers launch, fail, or expire
- Alert fires when an agent is stopped

**Reference solution should include:** `agent/metrics.py`, `infra/prometheus.yml`, dashboard JSON.

---

## Phase 6 — Experience

### Lab 13 — Real-Time Log Streaming with Redis + SSE

**Goal:**
Elasticsearch is great for searching the past. For watching logs live, stream them straight to the browser.

**What you will build:**
- Redis on `control-01`
- Agent log publisher: follows each container's Docker logs and publishes to `logs:{tenant_id}:{container_id}`
- `GET /logs/stream?container_id=...` SSE endpoint with JWT and tenant checks

**Steps:**
1. Add the publisher to the agent, started when a container launches and stopped when it is removed.
2. Implement the SSE endpoint: verify token, confirm container ownership, subscribe to the channel, stream `data:` events, send periodic keep-alive comments.
3. Handle client disconnects cleanly (unsubscribe).
4. Test with `curl -N`.
5. Note the browser limitation: `EventSource` cannot set an `Authorization` header, so issue a short-lived stream token or use a cookie.

**Expected output:**
- `curl -N` shows log lines as they are printed
- Streaming another tenant's container returns `403`
- Disconnecting the client frees the Redis subscription

**Reference solution should include:** `agent/log_publisher.py`, `control-plane/stream.py`, a comparison of SSE vs WebSockets for this use case.

---

### Lab 14 — Tenant Web UI

**Goal:**
Give tenants a place to see and control their workloads, showing only their own data.

**What you will build:**
- A web UI with Authentik login (authorization code flow with PKCE)
- Pages: container list with status, launch form, container detail with metrics and live logs
- Historical logs via a control plane endpoint that queries Elasticsearch filtered by tenant

**Steps:**
1. Implement login and token handling.
2. Build the container list and launch form using the protected APIs.
3. Build the detail view: metrics (via control plane proxy to Prometheus), historical logs (via Elasticsearch proxy), live logs (via `EventSource`).
4. Confirm every call is scoped by the token's tenant.

**Expected output:**
- Alice and Bob each see only their own containers, logs, and metrics
- Launching and stopping from the UI works end to end

**Reference solution should include:** `web-ui/` source, proxy endpoints for logs and metrics.

---

## Phase 7 — Integration

### Lab 15 — Capstone: Isolation Tests and End-to-End Demo

**Goal:**
Prove the platform is correct and isolated, exactly as the exam evaluates it.

**What you will do:**
- Run an automated isolation test suite
- Perform a full end-to-end demo with two tenants

**Steps:**
1. Network isolation: `beta` containers cannot reach `alpha` IPs, even on the same node.
2. API isolation: every endpoint rejects cross-tenant access.
3. Log isolation: Elasticsearch queries through the control plane never return other tenants' logs.
4. Stream isolation: SSE rejects cross-tenant streams.
5. Resilience: kill an agent, restart the control plane, expire a TTL; confirm the system recovers and statuses stay correct.
6. Record a demo walking through every exam evaluation criterion.

**Expected output:**
- Isolation test suite passes
- Demo covers login, launch, scheduling, lifecycle, logs, metrics, live streaming

**Reference solution should include:** `tests/isolation/`, a demo checklist mapped to evaluation criteria.

---

### Lab 16 — (Optional) Service Discovery with Route 53

**Goal:**
Give tenant services stable names (e.g. `web.alpha.swarm.local`) instead of raw IPs.

**Steps:**
1. Create a Route 53 Private Hosted Zone attached to the VPC.
2. Upsert an A record when a container launches, delete it when it stops (as activities in the lifecycle workflow).
3. Verify with `dig` from any node.

**Expected output:** DNS names resolve to current container IPs and disappear when containers stop.

---

## Coverage check against exam evaluation criteria

| Evaluation criterion | Covered in |
|---|---|
| Auth and multi-tenancy isolation | Labs 04, 05, 09, 10, 15 |
| Agent registration and container deployment | Labs 02, 03, 06, 08 |
| Log data structure in Elasticsearch | Lab 11 |
| Temporal integration with clear workflows | Labs 06, 07 |
| Prometheus metrics endpoint and Grafana dashboard | Lab 12 |
| Tenant-isolated web interface | Lab 14 |
| SSE log streaming tied to tenant/container | Lab 13 |

---

## Bare minimum vs full: what the extra labs buy you

| Full-plan labs | Merged into bare-minimum lab | What the split adds |
|---|---|---|
| 01, 02, 03 | 01 | Separate checkpoints for registration vs heartbeats |
| 04, 05 | 02 | IPAM taught properly instead of hardcoded ranges |
| 06, 07, 08 | 03 | Real best-fit scheduler, signals, `continue_as_new`, restart resilience |
| 09, 10 | 04 | Tested authorization rules |
| 13, 14 | 07 | Proper UI with historical logs and launch form |
| 15 | — | Explicit isolation test suite |
| 16 | — | Route 53 service discovery |
