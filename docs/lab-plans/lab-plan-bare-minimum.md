# Lab Plan (Bare Minimum): Build a Multi-Tenant Agent Cloud

**Course:** Build Your Own ECS: Multi-Tenant Container Orchestration (Python track)
**Final exam target:** Multi-Tenant Agent Cloud with SSO and Centralized Logging
**Total labs:** 7 (+ an author-only platform check before Lab 01)
**Estimated student time:** ~20–24 hours total, including per-lab catch-up and cleanup
**Audience:** Students / event participants
**Prerequisites:** Linux CLI, Python, Docker basics, basic HTTP/REST
**Platform:** Poridhi VS Code workspace + temporary AWS account (see `PORIDHI_PLATFORM.md`)

---

## Philosophy of this plan

Every exam evaluation criterion is covered **at least once**, with related topics merged so there are fewer documents and solutions to prepare. The **code** builds up from lab to lab, but the **environment does not**: every Poridhi lab launch is a brand-new workspace and a fresh set of AWS credentials. So each lab after the first opens with a scripted **catch-up** that rebuilds the previous lab's end state in a few minutes, and every lab ends by destroying its EC2 instances.

What this plan deliberately keeps simple:

- Scheduling is a "most free memory that fits" pick, not a full best-fit scheduler.
- The Web UI is a single HTML page served by the control plane.
- Kibana views are basic filtered views.
- Route 53 service discovery and multi-replica deployment are skipped. The exam does not require them.

---

## Changes from the previous version of this plan

| Change | Why |
|---|---|
| Labs reordered: logging and metrics now come **before** SSO | Authentik is the hardest thing to rebuild in a catch-up (its redirect URIs depend on EC2 public IPs, which change every session). Moving it late means only the last two labs carry it. Logging and metrics don't depend on auth. |
| One all-in-one `t3.xlarge` replaced by a **per-lab machine layout** of `t3.medium`s | Only `t2.micro` and `t3.medium` are confirmed allowed by the Poridhi AWS policy. Larger types are untested. |
| Every lab gets **Catch-up** and **Cleanup** sections | Environments never persist between labs; EC2 is billed per hour. |
| Machines provisioned with **Terraform** from the workspace | Terraform and AWS CLI are preinstalled; no Pulumi signup step. |
| Web UIs reached via **EC2 public IP + opened port**, not SSH tunnels | Unknown whether a workspace SSH tunnel is reachable from the student's browser. Still to be verified. |
| Student-facing titles have **no lab numbers** | Poridhi shows labs by title only. Numbers stay in folder names and git tags. |
| Authentik configured **by script (blueprints/API)**, not by clicking | It must be re-created in every catch-up. |

---

## Lab 00 (author only) — Platform check

Not published to students. Run once on a real Poridhi AWS lab before writing Lab 01, and record results in `PORIDHI_PLATFORM.md`.

1. Probe instance types with `--dry-run`: `t3.large`, `t3.xlarge`, `t3.2xlarge`. Try `aws iam get-user-policy --policy-name RestrictedAccessPolicy` to read the full allow-list.
2. Check whether 5 `t3.medium` instances can run at once (instance cap).
3. Start a web server on an EC2 instance with the port open in its security group, and confirm the student's browser can reach `http://<public-ip>:<port>`.
4. Try the Poridhi Load Balancer against an EC2 public IP.
5. Check whether Elastic IPs are allowed (would give Authentik stable URLs).
6. Check whether `<details>` blocks render in the Poridhi lab viewer.
7. Check Python version in the workspace.
8. Confirm the course repo can be cloned publicly from EC2 (needed by every catch-up).

**If `t3.xlarge` is allowed**, the layout below can collapse `control-01`, `obs-01`, and `auth-01` into one machine. **If the instance cap is below 5**, the capstone layout needs rethinking.

---

## Machine layout per lab

All instances are `t3.medium` (2 vCPU / 4 GB), Ubuntu 24.04, region `ap-southeast-1`, AZ `ap-southeast-1a`, login user `ubuntu`. Docker is installed via `user_data`.

| Machine | Runs | Needed from |
|---|---|---|
| `control-01` | FastAPI control plane, Postgres, Temporal + UI, Prometheus, Grafana, Redis | Lab 01 |
| `node-01`, `node-02` | Agent (with Temporal worker), Docker, Fluent Bit, Node Exporter | Lab 01 |
| `obs-01` | Elasticsearch, Kibana | Lab 04 |
| `auth-01` | Authentik (server, worker, its Postgres and Redis) | Lab 06 |

| Lab | Instances |
|---|---|
| 01–03 | 3 (control, node-01, node-02) |
| 04 | 4 (+ obs-01) |
| 05 | 3 (logging not needed for metrics) |
| 06 | 4 (+ auth-01) |
| 07 | 5 (everything) |

**Tenants used throughout:** `alpha` (VXLAN ID 100, subnet `10.10.1.0/24`) and `beta` (VXLAN ID 200, subnet `10.10.2.0/24`).

**Network (Terraform):** VPC `10.0.0.0/16`, public subnet `10.0.1.0/24`, internet gateway. Security group: SSH from anywhere, **one `self = true` rule allowing all traffic between instances** (covers every internal port including VXLAN UDP 4789), and browser-facing UI ports opened from anywhere (short-lived labs).

---

## The catch-up mechanism (designed in Lab 01)

Every lab from 02 onward starts with the same four commands, run on the **workspace**:

1. Fetch fresh credentials from Cloud Tray, `aws configure`, and gate on `aws sts get-caller-identity`
2. `git clone` the course repo and `git checkout lab-NN-start`
3. `terraform apply` in `infra/terraform/` (the tag's config creates exactly the machines this lab needs)
4. `./scripts/catchup.sh` which installs dependencies on each machine, starts every service the previous lab left running, re-applies config (tenant networks, and from Lab 07, Authentik), and ends with a verification check

**Git tags:** `lab-NN-start` = previous lab's solution + this lab's infra; `lab-NN-solution` = end of this lab.

---

## Lab list at a glance

| # | Folder | Student-facing title | Exam sections |
|---|---|---|---|
| 01 | `lab-01-control-plane` | Building the Control Plane and Registering Agents | 2 |
| 02 | `lab-02-vxlan` | Isolating Tenants with a VXLAN Overlay Network | 2, 3 |
| 03 | `lab-03-lifecycle` | Managing Container Lifecycles with Temporal | 3, 5 |
| 04 | `lab-04-logging` | Centralized Logging with Fluent Bit and Elasticsearch | 4 |
| 05 | `lab-05-metrics` | Monitoring the Cluster with Prometheus and Grafana | 6 |
| 06 | `lab-06-sso` | Multi-Tenant SSO with Authentik | 1 |
| 07 | `lab-07-capstone` | Real-Time Log Streaming and the Tenant Web UI | 7, 8 |

---

## Lab 01 — Building the Control Plane and Registering Agents

**Goal:**
Provision the cluster, stand up the control plane, and build the agent that runs on every compute node. When an agent starts, it registers itself and keeps sending heartbeats with its capacity. This lab also builds the Terraform config and catch-up script every later lab reuses.

**What you will build:**
- Terraform config for `control-01`, `node-01`, `node-02` (VPC, subnet, security group, key pair, SSH config)
- Postgres + Temporal + Temporal UI on `control-01` via Docker Compose
- A FastAPI control plane with an agent registry (`agents` table)
- A Python agent that registers on startup and sends heartbeats every 10 seconds, run by systemd
- The first version of `scripts/catchup.sh`

**Steps:**
1. *(workspace)* Fetch credentials, `aws configure`, verify with `aws sts get-caller-identity` and the EC2 probe.
2. *(workspace)* Create the key pair, check its size, write the Terraform files, `terraform validate`, `terraform apply`.
3. *(control-01)* Bring up Postgres + Temporal with Docker Compose; open Temporal UI at `http://<control-public-ip>:8233`.
4. *(control-01)* Build the control plane: `POST /agents/register`, `POST /agents/{node_id}/heartbeat`, `GET /agents`, plus a background task marking agents `offline` after 30 seconds of silence. Agent endpoints use a shared agent token.
5. *(node-01, node-02)* Install the agent (`psutil` for CPU/memory) as a systemd service.
6. Break it on purpose: stop the agent on `node-02` and watch its status flip to `offline`, then start it again.
7. *(workspace)* Cleanup: `terraform destroy -auto-approve`, delete key pair, verify nothing is running.

**Expected output:**
- `GET /agents` shows both nodes `online` with capacity
- Stopping an agent marks it `offline` within ~30 seconds
- Temporal UI loads in the browser

**Reference solution should include:** `infra/terraform/*.tf`, `infra/control/docker-compose.yml`, `control-plane/main.py`, `agent/agent.py`, `agent/agent.service`, `scripts/catchup.sh`.

---

## Lab 02 — Isolating Tenants with a VXLAN Overlay Network

**Catch-up:** control plane + both agents running and registered.

**Goal:**
Give each tenant a private network that spans both compute nodes. `alpha` containers on different nodes can talk to each other; `beta` containers can't see `alpha` at all.

**What you will build:**
- `tenants` table and `POST /tenants/{tenant_id}/network` (allocates VXLAN ID + subnet)
- Agent endpoint `setup_tenant_network(...)` that creates, idempotently: a Docker bridge network with a fixed bridge name (`br-alpha`), the node's own IP range and gateway, a VXLAN interface, and FDB entries to each peer node
- Control plane calls it on every online agent

**Steps:**
1. *(control-01)* Implement allocation, idempotent (same tenant → same result).
2. *(nodes)* Implement network setup:
   - `ip link add vxlan100 type vxlan id 100 dstport 4789 dev ens5 nolearning` (detect the interface name rather than hardcoding it)
   - `bridge fdb append 00:00:00:00:00:00 dev vxlan100 dst <peer_private_ip>`
   - attach to the tenant bridge, bring up
3. Create both tenant networks from the control plane.
4. Run a test container per tenant per node; ping across nodes; ping with a large packet to check MTU.
5. Break it on purpose: delete a node's FDB entry and watch cross-node ping fail, then restore it.
6. Confirm `beta` cannot reach `alpha`, including on the same node.
7. Cleanup.

**Expected output:**
- `ip link show` shows `vxlan100`, `vxlan200`, `br-alpha`, `br-beta` on both nodes
- `alpha` → `alpha` cross-node ping succeeds; `beta` → `alpha` fails

**Reference solution should include:** `agent/network.py`, diagram of bridge + VXLAN + NIC per node, pitfalls (interface name, distinct gateways, idempotency). Catch-up must re-create tenant networks from Postgres.

---

## Lab 03 — Managing Container Lifecycles with Temporal

**Catch-up:** control plane, agents, and both tenant networks up.

**Goal:**
Launch tenant containers through Temporal workflows and keep managing them: health checks, failure handling, and automatic cleanup when their TTL expires.

**What you will build:**
- A Temporal worker inside the agent on a node-specific task queue (`node-01`, `node-02`, based on the registered node ID, never the random hostname)
- Activities: `launch_container`, `check_container`, `stop_container` (Docker SDK); containers labeled `tenant_id`, `node_id`
- `ContainerLifecycleWorkflow` and `POST /containers` (`tenant_id`, `image`, `cpu`, `mem`, `ttl_seconds`)
- Simple scheduling from heartbeat data

**Steps:**
1. Add the Temporal worker to the agent.
2. Implement the three activities.
3. Implement scheduling: online agent with the most free memory that fits.
4. Write the workflow: launch on the chosen node's queue → loop with durable timers every 15s → stop after 3 failed checks or TTL.
5. Test TTL with `ttl_seconds=120`.
6. Break it on purpose: `docker kill` a container and watch the workflow mark it `failed`.
7. Cleanup.

**Expected output:**
- Temporal UI shows each container's full lifecycle
- TTL expiry and failure detection both work; `containers` table shows correct statuses

**Reference solution should include:** `control-plane/workflows.py`, `agent/activities.py`, explanation of durable timers.

---

## Lab 04 — Centralized Logging with Fluent Bit and Elasticsearch

**Catch-up:** everything from the lifecycle lab, plus `obs-01` provisioned.

**Goal:**
Collect every container's logs from every node into one searchable place, tagged with tenant, container, and node.

**What you will build:**
- Elasticsearch (single node, explicit heap sized for 4 GB) + Kibana on `obs-01`
- Fluent Bit on each node; containers use Docker's `fluentd` log driver pointed at it
- Log records with `tenant_id`, `container_id`, `node_id`
- One Kibana view per tenant

**Steps:**
1. *(obs-01)* Set `vm.max_map_count=262144` persistently, start Elasticsearch + Kibana, wait for health green/yellow.
2. *(nodes)* Configure Fluent Bit: `forward` input, add `node_id`, `es` output.
3. Update `launch_container` to use the `fluentd` log driver and pass the `tenant_id` label.
4. Launch a chatty container per tenant.
5. In Kibana (`http://<obs-public-ip>:5601`), create a data view and one saved view per tenant.
6. Break it on purpose: stop Fluent Bit on a node, watch that node's logs stop arriving, restart it.
7. Cleanup.

**Expected output:**
- Documents contain `tenant_id`, `container_id`, `node_id`, `log`
- Per-tenant Kibana views show only that tenant's logs

**Reference solution should include:** `infra/fluent-bit/fluent-bit.conf`, `infra/obs/docker-compose.yml`, sample document, sample tenant query.

---

## Lab 05 — Monitoring the Cluster with Prometheus and Grafana

**Catch-up:** everything from the lifecycle lab (logging not needed).

**Goal:**
Make the cluster observable: each agent exposes metrics, Prometheus collects them, Grafana visualizes them.

**What you will build:**
- Agent `/metrics`: `agent_cpu_free`, `agent_mem_free_bytes`, `agent_active_containers{tenant_id}`
- Node Exporter on both nodes
- Prometheus + Grafana on `control-01` (Grafana at `:3000`), with a provisioned data source and dashboard

**Steps:**
1. Add metrics with `prometheus_client`.
2. Run Node Exporter on both nodes.
3. Configure Prometheus scrape jobs using the nodes' private IPs.
4. Provision Grafana's data source and dashboard from files (so catch-up can restore them).
5. Launch and expire containers; watch panels change.
6. Break it on purpose: stop an agent and watch its target go `DOWN`.
7. Cleanup.

**Expected output:**
- All Prometheus targets `UP`
- Dashboard shows node resources and active containers per tenant

**Reference solution should include:** `infra/control/prometheus.yml`, Grafana provisioning files + dashboard JSON, `agent/metrics.py`.

---

## Lab 06 — Multi-Tenant SSO with Authentik

**Catch-up:** everything from the lifecycle lab, plus `auth-01` provisioned.

**Goal:**
Put identity in front of the control plane. Users log in through Authentik, belong to a tenant group, and get a JWT. The control plane verifies it on every request and scopes everything to the token's tenant.

**What you will build:**
- Authentik on `auth-01` via Docker Compose
- Groups `tenant-alpha`, `tenant-beta`; users `alice`, `bob`; an OAuth2/OpenID provider (RS256) and application, with the `groups` claim in tokens
- All of the above created **by a script** (Authentik blueprints or API) with URLs templated from the current public IPs
- `control-plane/auth.py`: JWKS verification (signature, issuer, audience, expiry) and a `current_tenant` dependency

**Steps:**
1. *(auth-01)* Deploy Authentik with a bootstrap admin token set via environment variables.
2. Run the setup script to create groups, users, provider, and application.
3. Obtain a token for `alice` and decode it to confirm the `groups` claim.
4. Protect `/containers` endpoints: tenant comes from the token, never the body. `401` for missing/invalid tokens, `403` for cross-tenant access. Agent endpoints keep the agent token.
5. Break it on purpose: use an expired token, then Bob's token on Alice's container.
6. Cleanup.

**Expected output:**
- No token → `401`; Alice sees only `alpha`; Bob on an `alpha` container → `403`

**Reference solution should include:** `infra/auth/docker-compose.yml`, `scripts/authentik-setup.*`, `control-plane/auth.py`, token-fetch script.

⚠️ **Test a real browser login against an EC2 public IP before writing this lab.** Issuer and redirect URIs must match exactly what the browser uses.

---

## Lab 07 — Real-Time Log Streaming and the Tenant Web UI (Capstone)

**Catch-up:** everything (5 instances), including Authentik re-configured for this session's IPs.

**Goal:**
Stream container logs to the browser live, and bring the whole platform together in a small web page where a logged-in user sees only their tenant's containers, status, metrics, and logs.

**What you will build:**
- Agent log publisher: follows each container's Docker logs, publishes to Redis channel `logs:{tenant_id}:{container_id}`
- `GET /logs/stream?container_id=...` SSE endpoint with token + ownership checks and keep-alives
- `index.html` served by the control plane itself (same origin, no CORS): Authentik login, container list, metrics, live log panel via `EventSource`

**Steps:**
1. Add the publisher to the agent (start on launch, stop on removal).
2. Implement the SSE endpoint; test with `curl -N`.
3. Handle the browser limitation: `EventSource` cannot send an `Authorization` header, so issue a short-lived stream token as a query parameter.
4. Build the page: login, list containers, show metrics (control plane proxies Prometheus), live logs.
5. Final demo: Alice and Bob in separate browsers, each seeing only their own data.
6. Break it on purpose: Alice requests a `beta` stream → `403`.
7. Cleanup.

**Expected output:**
- Log lines appear in the browser within about a second
- Each tenant sees only its own containers, metrics, and logs

**Reference solution should include:** `agent/log_publisher.py`, `control-plane/stream.py`, `web-ui/index.html`, end-to-end demo checklist mapped to the evaluation criteria.

---

## Coverage check against exam evaluation criteria

| Evaluation criterion | Covered in |
|---|---|
| Auth and multi-tenancy isolation | Labs 02, 06 |
| Agent registration and container deployment | Labs 01, 03 |
| Log data structure in Elasticsearch | Lab 04 |
| Temporal integration with clear workflows | Lab 03 |
| Prometheus metrics endpoint and Grafana dashboard | Lab 05 |
| Tenant-isolated web interface | Lab 07 |
| SSE log streaming tied to tenant/container | Lab 07 |

---

## Risks

- **Platform unknowns block the plan.** Instance types, instance cap, and browser access to EC2 must be confirmed in Lab 00 before Lab 01 is written.
- **Catch-up time grows.** Later labs rebuild a heavy stack; the catch-up must stay fully scripted and non-interactive. Target under 10 minutes.
- **Authentik is fragile across sessions.** Changing public IPs break issuer and redirect URIs unless the setup script re-templates them.
- **Labs 03 and 07 are dense.** Split using the full plan if testing shows they run too long.
- **Cost.** Every lab must end with `terraform destroy` and a leftover check.
