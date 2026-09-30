# CLAUDE.md

Context for Claude Code. Read this fully, then read `PORIDHI_PLATFORM.md`, before doing anything in this repo.

---

## What this project is

We are preparing **hands-on labs (lab documents + tested reference solutions)** for Poridhi.io's course **"Build Your Own ECS: Multi-Tenant Container Orchestration"** (Python track). The audience is **students / event participants**, not experts.

The labs prepare students for the course's **final exam**: *"Build a Multi-Tenant Agent Cloud with SSO and Centralized Logging."* The exam PDF is in `docs/reference/`. Summary below.

We are short on time, so we are building the **bare minimum plan (7 labs)**:

- `docs/lab-plans/lab-plan-bare-minimum.md` ← **the plan we are executing**
- `docs/lab-plans/lab-plan-full.md` ← reference only (15 labs), for when a lab needs more depth or splitting
- `PORIDHI_PLATFORM.md` ← **how Poridhi workspaces, AWS accounts, and the browser terminal actually behave.** Facts marked ✅ are verified on real runs; ⚠️ are assumptions to test. When a lab depends on a ⚠️ item, tell Adid and get it tested early.

Every lab needs **two deliverables**: a student-facing lab document and a tested reference solution.

---

## About the person you're working with

Adid is a software engineer moving into backend and infrastructure engineering. Strong algorithms background, comfortable with Python, has used Temporal at work, newer to container networking, VXLAN, Authentik, and the observability stack. He runs every lab on a real Poridhi environment and pastes output back.

When explaining concepts: start from the problem, use intuitive analogies and concrete examples, show how each piece fits the whole system, be direct.

---

## Exam spec summary

Each tenant:
1. Authenticates via **SSO using Authentik** (tenant = Authentik group, JWTs, all APIs protected)
2. Launches isolated containers via a **custom control plane**
3. Has logs collected in **Elasticsearch**, tagged `tenant_id`, `container_id`, `node_id`; per-tenant **Kibana** views
4. Sees metrics via **Prometheus + Grafana** and a **Web UI**
5. Has container lifecycle orchestrated by **Temporal** (launch, health monitoring, auto-termination on failure or TTL)
6. Streams live logs via **SSE** (agent → Redis channel per container → SSE endpoint → browser `EventSource`)

**Agent** = a lightweight Python program on each compute node that registers with the control plane, sends heartbeats with capacity, operates per-tenant VXLAN bridges, and executes container operations (like the ECS Agent / kubelet). The Temporal worker runs *inside* the agent.

**Evaluation criteria:** auth + tenant isolation, reliable agent registration and deployment, structured logs in ES, clear Temporal workflows, Prometheus endpoint + Grafana dashboard, tenant-isolated web UI, SSE streaming tied to tenant/container.

---

## Status

| # | Folder | Student-facing title | Status |
|---|---|---|---|
| 00 | — | Platform check (author only, not published) | not started |
| 01 | `lab-01-control-plane` | Building the Control Plane and Registering Agents | not started |
| 02 | `lab-02-vxlan` | Isolating Tenants with a VXLAN Overlay Network | not started |
| 03 | `lab-03-lifecycle` | Managing Container Lifecycles with Temporal | not started |
| 04 | `lab-04-logging` | Centralized Logging with Fluent Bit and Elasticsearch | not started |
| 05 | `lab-05-metrics` | Monitoring the Cluster with Prometheus and Grafana | not started |
| 06 | `lab-06-sso` | Multi-Tenant SSO with Authentik | not started |
| 07 | `lab-07-capstone` | Real-Time Log Streaming and the Tenant Web UI | not started |

Update this table as work progresses (`drafted`, `solution built`, `tested on Poridhi`, `done`).

Note the order: logging and metrics come **before** SSO on purpose, so only the last two catch-ups carry Authentik.

---

## The platform in one screen (details in PORIDHI_PLATFORM.md)

- Students work in a **browser VS Code workspace** (a Poridhi VM, user `poridhian`, starts in `~/code`) with AWS CLI + Terraform preinstalled, and a **temporary AWS account**.
- **Every lab launch is a brand-new workspace and new IAM credentials.** Nothing survives: no EC2 access, no SSH key, no Terraform state, no repo clone, no running services.
- Region `ap-southeast-1`, AZ `ap-southeast-1a`. No default VPC. EC2 login user `ubuntu`.
- **Confirmed allowed instance types: `t2.micro`, `t3.medium` only.** Everything else is untested or denied.
- Only the workspace holds the SSH key; EC2 instances **cannot SSH to each other**.
- Every lab must end with `terraform destroy` + key-pair deletion + a leftover check.

---

## Fixed technical decisions

Do not change these without asking.

- **Language:** Python 3.11+ (control plane, agent, workflows)
- **Provisioning:** Terraform from the workspace; AMI looked up by filter, never hardcoded; `user_data` installs Docker and logs to `/var/log/bootstrap.log`
- **Machine layout:** all `t3.medium`, provisioned per lab as needed:

  | Machine | Runs | From lab |
  |---|---|---|
  | `control-01` | FastAPI, Postgres, Temporal + UI, Prometheus, Grafana, Redis | 01 |
  | `node-01`, `node-02` | Agent + Temporal worker, Docker, Fluent Bit, Node Exporter | 01 |
  | `obs-01` | Elasticsearch, Kibana | 04 |
  | `auth-01` | Authentik | 06 |

  If Lab 00 shows `t3.xlarge` is allowed, ask Adid before collapsing machines.
- **Network:** VPC `10.0.0.0/16`, public subnet `10.0.1.0/24`, security group with SSH from anywhere + **one `self = true` rule for all internal traffic** + browser-facing UI ports from anywhere
- **Browser access to UIs:** EC2 public IP + opened port (⚠️ to verify in Lab 00). No SSH tunnels in student steps.
- **Control plane:** FastAPI + Postgres. Also serves `web-ui/index.html` (same origin, no CORS).
- **Orchestration:** Temporal Python SDK; task queue per node named after the **registered node ID** (`node-01`), never the hostname
- **Agent → control plane:** HTTP with a shared agent token
- **Users → control plane:** Authentik JWT (RS256, JWKS); `tenant_id` from the `groups` claim, **never** from the request body
- **Authentik config:** created by script (blueprints or API), with issuer and redirect URIs templated from the current session's public IPs. Never by clicking in the UI.
- **Containers:** Docker SDK for Python; labels `tenant_id`, `node_id`
- **Networking:** per-tenant Docker bridge network with a fixed bridge name + VXLAN interface attached + static FDB entries to peers' private IPs; detect the NIC name (e.g. `ens5`), don't hardcode `eth0`
- **Logging:** Docker `fluentd` log driver → Fluent Bit per node → Elasticsearch on `obs-01`
- **Live logs:** agent publishes to Redis channel `logs:{tenant_id}:{container_id}`
- **Metrics:** `prometheus_client` on agent + Node Exporter; Grafana data source and dashboards **provisioned from files**
- **Scheduling:** online agent with the most free memory that fits, from heartbeat data
- **Web UI:** single `index.html`, vanilla JS

## Naming conventions

- Tenants: `alpha` (VXLAN 100, `10.10.1.0/24`), `beta` (VXLAN 200, `10.10.2.0/24`)
- Authentik groups `tenant-alpha`, `tenant-beta`; users `alice` (alpha), `bob` (beta)
- Bridges `br-alpha`, `br-beta`; VXLAN interfaces `vxlan100`, `vxlan200`
- Per-node IP ranges in each tenant subnet (`.10–.99` on node-01, `.110–.199` on node-02), each node with its own gateway
- Git tags: `lab-NN-start` (previous solution + this lab's infra) and `lab-NN-solution`

## Ports

Control plane 8000, agent 5050, Temporal 7233, Temporal UI 8233, Postgres 5432, Redis 6379, Elasticsearch 9200, Kibana 5601, Prometheus 9090, Grafana 3000, Authentik 9000, Node Exporter 9100, Fluent Bit forward 24224, VXLAN UDP 4789.

---

## The catch-up mechanism

Design it in Lab 01; every later lab reuses it. Run from the **workspace**:

1. Fresh credentials from Cloud Tray → `aws configure` → gate on `aws sts get-caller-identity` (and the EC2 probe, since EC2 validates credentials later than STS)
2. `git clone` the course repo, `git checkout lab-NN-start`
3. `terraform apply` in `infra/terraform/`
4. `./scripts/catchup.sh`: installs dependencies on each machine, starts everything the previous lab left running, re-applies state (tenant networks from Postgres; Authentik config with this session's IPs), ends with a verification check

Must be **scripted and non-interactive**. Target under 10 minutes. Students never redo earlier labs by hand.

---

## Repo layout

```
.
├── CLAUDE.md
├── PORIDHI_PLATFORM.md
├── docs/
│   ├── lab-plans/            # the two plan files
│   ├── reference/            # exam PDF
│   └── labs/
│       ├── lab-01-control-plane/
│       │   ├── README.md     # the lab document
│       │   └── images/
│       └── ...
├── infra/
│   ├── terraform/            # *.tf split into small files
│   ├── control/              # docker-compose, prometheus.yml, grafana provisioning
│   ├── obs/                  # elasticsearch + kibana compose
│   ├── auth/                 # authentik compose + setup script
│   └── fluent-bit/
├── control-plane/
├── agent/
├── web-ui/
└── scripts/                  # catchup.sh, verify.sh
```

---

## Lab document template

```markdown
# Title                          ← title only, no lab number

## Overview
The problem this lab solves, how it connects to earlier labs (by **bold title**,
never by number), and to the final exam. One intuitive analogy.

## Architecture
Mermaid diagram (placeholder; the team redraws it as a PNG).

## Catch-up                      ← every lab except the first
The four catch-up commands and the verification that proves they worked.

## Concepts
New concepts, problem first.

## Steps
5–8 numbered steps. Every command block labeled with the machine it runs on
(workspace, control-01, node-01 ...). Explain every flag the first time.
After a step that creates many things, say what now exists and where.

## Break it on purpose
One deliberate failure to cause, observe, and fix.

## Verification
Exact commands and REAL output from a tested run.

## Troubleshooting
Known failures and fixes.

## Cleanup
terraform destroy, delete key pair, leftover check.

## Summary
What was built, and what the **next lab's title** adds.
```

---

## Writing rules for commands (from real failures, see PORIDHI_PLATFORM.md §6)

- Label every command block with its machine. Have students run `hostname` before destructive steps.
- Never nest `ssh host "..."` inside a step that runs on another machine; nodes can't SSH to each other anyway.
- Never put `<placeholder>` in a shell command; use shell variables set earlier, or `VALUE_HERE`.
- Use `grep --color=never` whenever capturing grep output.
- Keep heredocs short; verify files after writing them (`terraform validate`, `cat`, a linter). Don't diagnose truncation from the echo.
- Background processes must redirect output: `cmd > /tmp/x.log 2>&1 &`.
- Wait explicitly for async things (`until curl -sf ...; do sleep 2; done`), never a bare `sleep`.
- `sudo` with globs needs `sudo sh -c '...'`.
- Never write real AWS keys into docs or commits.
- Never hardcode AMI IDs, hostnames, or public IPs.

---

## How to work

1. **Lab 00 first.** Produce an author checklist + small scripts for the open platform questions (instance types, instance cap, browser access to EC2, Elastic IPs, `<details>` rendering, Python version, public repo clone). Adid runs them; record answers in `PORIDHI_PLATFORM.md` (⚠️ → ✅).
2. **One lab at a time.** Solution first, then the document written from what actually worked.
3. **Expected output is never invented.** Draft output is marked `<!-- UNTESTED -->` until Adid pastes a real run; then replace it with the real output.
4. **When a command fails on the real platform**, fix it and record *why* in the "Lessons learned" section below so later labs don't repeat it.
5. **Teaching code, not production code.** Minimal, readable, comment the non-obvious.
6. **Ask before** changing a fixed decision, adding a dependency, or restructuring the repo.
7. If a lab is too dense, say so and propose a split using the full plan.
8. Update the Status table after each lab.

---

## Known technical pitfalls to cover in the docs

- **VXLAN:** setup must be idempotent; distinct gateway and IP range per node; FDB entries use peers' private IPs; verify MTU with a large-packet ping (VPC jumbo frames make it unlikely to bite). Run on EC2 only, never on the Poridhi VM (custom kernel may lack modules).
- **Isolation:** verify `beta` cannot reach `alpha`, including on the same node.
- **Temporal:** health loops in the workflow with durable timers; `continue_as_new` for long-lived workflows; idempotent activities.
- **Auth:** verify signature, issuer, audience, expiry; cache JWKS; 401 vs 403; `groups` claim present; issuer/redirect URIs must exactly match the browser URL.
- **SSE:** `EventSource` can't send `Authorization`; use a short-lived stream token in the query string; keep-alives; unsubscribe from Redis on disconnect.
- **Elasticsearch:** `vm.max_map_count=262144` set persistently; explicit heap sized for a 4 GB machine.
- **Heartbeats:** offline after ~30s without one.

---

## Lessons learned

*(Append here whenever a real Poridhi run breaks something: what failed, why, and the fix.)*

---

## Current state

Planning done. Next: **Lab 00 platform check**, then Lab 01 (reference solution first).
