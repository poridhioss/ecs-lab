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
| 00 | `lab-00-platform-check` | Platform check (author only, not published) | done |
| 01 | `lab-01-control-plane` | Building the Control Plane and Registering Agents | **done**: tested on Poridhi, all output in the doc is real; branches `lab-01-start`, `lab-01-solution` |
| 02 | `lab-02-vxlan` | Isolating Tenants with a VXLAN Overlay Network | solution built, doc drafted (outputs UNTESTED), branch `lab-02-start`; not tested on Poridhi |
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
- **Allowed instance types: `t2.micro`, `t2.small`, `t3.medium` only** (read from the IAM policy in Lab 00; everything larger is denied). 5 `t3.medium`s run at once fine.
- EC2 NIC is `ens5`, MTU 9001; `vxlan` module loads; Python 3.12.3. Route 53 is not permitted.
- Only the workspace holds the SSH key; EC2 instances **cannot SSH to each other**.
- Every lab must end with `terraform destroy` (which also deletes the Terraform-made key pair) + a leftover check (`scripts/destroy.sh` does both).

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

  Lab 00 confirmed nothing larger than `t3.medium` is allowed, so this split layout is final.
- **Network:** VPC `10.0.0.0/16`, public subnet `10.0.1.0/24`, security group with SSH from anywhere + **one `self = true` rule for all internal traffic** + browser-facing UI ports from anywhere (`public_ports` variable)
- **Fixed private IPs** (Terraform `machines` map): `control-01` 10.0.1.10, `node-01` 10.0.1.21, `node-02` 10.0.1.22, `obs-01` 10.0.1.30, `auth-01` 10.0.1.40. Every config can name its peers up front, with no dependency cycles (e.g. Prometheus on control-01 needs node IPs while nodes need control-01's IP). Only public IPs change per session.
- **Per-machine settings:** `user_data` writes `/etc/ecs-lab/ecs-lab.env` (`NODE_ID`, `CONTROL_IP`, `AGENT_TOKEN`); systemd units read it with `EnvironmentFile=`. The agent token is a Terraform `random_password`, new every session. Agents send it as the `X-Agent-Token` header (keeps `Authorization` free for user JWTs).
- **SSH key made by Terraform** (`tls_private_key` + `aws_key_pair`, written to `~/.ssh/ecs-lab-key.id_rsa`), so `terraform destroy` removes it: no manual key-pair step, no zero-byte key file.
- **Temporal:** the `temporalio/temporal` image running `server start-dev` (server + UI in one process, SQLite file on a volume, UI on 8233). Lighter than the multi-container auto-setup stack on a 4 GB machine.
- **Deploy layout:** code under `/opt/ecs-lab/` on each machine, one venv at `/opt/ecs-lab/venv`; each component has an idempotent `install.sh`. `scripts/push.sh infra|control-plane|agent|all` copies and runs it.
- **Browser access to UIs:** EC2 public IP + opened port (✅ verified in Lab 00). No SSH tunnels, no Poridhi Load Balancer (it rejects public IPs).
- **Docker version pinned:** `curl -fsSL https://get.docker.com | sh -s -- --version 29.8` in `user_data`, so a future Docker release can't change networking/firewall behaviour under the labs.
- **Control plane:** FastAPI + Postgres. Also serves `web-ui/index.html` (same origin, no CORS).
- **Code delivery:** students edit code in the workspace VS Code; `scripts/push.sh` copies it to the EC2 machines (`tar czf - ... | ssh HOST tar xzf -`; the workspace has no `rsync`) and restarts services. Catch-up uses the same script. EC2 machines never clone the repo.
- **Orchestration:** Temporal Python SDK; task queue per node named after the **registered node ID** (`node-01`), never the hostname. Activities run on the node queues; **workflows run on a worker on `control-01`** (task queue `lifecycle`), so a dead node can still be marked `failed`.
- **Agent → control plane:** HTTP with a shared agent token
- **Control plane → agent:** the agent runs its own FastAPI on port 5050 (same event loop as heartbeats, `uvicorn.Server`), same `X-Agent-Token` check. `PUT /networks/{tenant_id}` builds a tenant network on that node and returns the list of changes (empty = already up to date).
- **Tenant allocation:** `POST /tenants/{tenant_id}/network` (idempotent): n-th tenant gets VXLAN `n*100` and `10.10.n.0/24`. Node slices come from a fixed `NODE_SLOTS` map in the control plane (`node-01` → lower `/25`, `node-02` → upper `/25`, gateway = first host of the slice). Tenant IDs: `^[a-z][a-z0-9]{0,11}$` (`br-` + 12 = 15-char interface name limit).
- **Tenant networks on the node:** Docker network named after the tenant (bridge `br-<tenant>`, label `tenant_id`), `vxlan<id>` with `nolearning` on the default-route NIC, all-zeros FDB entries per peer (AWS VPCs have no multicast, so peers are listed statically). Not persistent across reboots or sessions: re-run the endpoint (catch-up does).
- **Test containers:** `busybox:1.37` with static `--ip` (node-01: `.10`, node-02: `.140`).
- **Users → control plane:** Authentik JWT (RS256, JWKS); `tenant_id` from the `groups` claim, **never** from the request body
- **Browser login:** authorization code flow with the **code exchanged by the control plane** (`/callback`, confidential client with a secret). Not browser PKCE: `crypto.subtle` doesn't exist on a plain-HTTP public-IP origin.
- **Authentik config:** created by script (blueprints or API), with issuer and redirect URIs templated from the current session's public IPs. Never by clicking in the UI.
- **Containers:** Docker SDK for Python; labels `tenant_id`, `node_id`
- **Networking:** per-tenant Docker bridge network with a fixed bridge name + VXLAN interface attached + static FDB entries to peers' private IPs; detect the NIC name (e.g. `ens5`), don't hardcode `eth0`
- **Logging:** Docker `fluentd` log driver → Fluent Bit per node → Elasticsearch on `obs-01`
- **Live logs:** agent publishes to Redis channel `logs:{tenant_id}:{container_id}`. SSE endpoint is `/logs/stream?tenant_id=...&container_id=...` (the exam's shape); `tenant_id` must match the token's tenant, else `403`.
- **Historical logs:** `GET /containers/{id}/logs` on the control plane queries Elasticsearch filtered by the token's tenant (the exam's "Elasticsearch/Kibana proxy" for the Web UI).
- **Metrics:** `prometheus_client` on agent + Node Exporter; Grafana data source and dashboards **provisioned from files**
- **Scheduling:** online agent with the most free memory that fits, from heartbeat data
- **Web UI:** single `index.html`, vanilla JS

## Naming conventions

- Tenants: `alpha` (VXLAN 100, `10.10.1.0/24`), `beta` (VXLAN 200, `10.10.2.0/24`)
- Authentik groups `tenant-alpha`, `tenant-beta`; users `alice` (alpha), `bob` (beta)
- Bridges `br-alpha`, `br-beta`; VXLAN interfaces `vxlan100`, `vxlan200`
- Per-node IP ranges in each tenant subnet, as CIDR blocks because Docker's `--ip-range` only accepts CIDR: node-01 `x.x.x.0/25` with gateway `.1`, node-02 `x.x.x.128/25` with gateway `.129` (e.g. alpha: `10.10.1.0/25` gw `10.10.1.1`, `10.10.1.128/25` gw `10.10.1.129`)
- **Repo:** https://github.com/poridhioss/ecs-lab.git (public). Git **branches**, not tags:
  - `main`: authoring branch. Everything, including author-only files and the newest code. Students never use it.
  - `lab-NN-start`: what students clone (`git clone -b lab-NN-start --depth 1 https://github.com/poridhioss/ecs-lab.git`). Lab 01: infra + scripts + install/unit files, **without** the files students write (`control-plane/main.py`, `agent/agent.py`). Later labs: previous lab's full solution + this lab's new infra.
  - `lab-NN-solution`: finished reference for lab NN.
  - Branches are cut from `main` only after a lab passes on Poridhi. A later fix is committed on `main`, then cherry-picked into each affected lab branch.

## Ports

Control plane 8000, agent 5050, Temporal 7233, Temporal UI 8233, Postgres 5432, Redis 6379, Elasticsearch 9200, Kibana 5601, Prometheus 9090, Grafana 3000, Authentik 9000, Node Exporter 9100, Fluent Bit forward 24224, VXLAN UDP 4789.

---

## The catch-up mechanism

Design it in Lab 01; every later lab reuses it. Run from the **workspace**:

1. Fresh credentials from Cloud Tray → `aws configure` → gate on `aws sts get-caller-identity` (and the EC2 probe, since EC2 validates credentials later than STS)
2. `git clone -b lab-NN-start --depth 1` the course repo, then **leftover check**: `bash scripts/preflight.sh` (deletes any `ecs-lab-vpc` / `ecs-lab-key` an earlier session left; usually prints `clean`). Show the check command inline in the doc so students see what it looks for.
3. `terraform apply` in `infra/terraform/`
4. `./scripts/catchup.sh`: pushes the code with `push.sh`, installs dependencies on each machine, starts everything the previous lab left running, re-applies state (tenant networks from Postgres; Authentik config with this session's IPs), ends with a verification check

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

## Before you start               ← every lab, including the first
Fresh credentials + STS/EC2 gate, clone, then the leftover check: show
`aws ec2 describe-vpcs --filters "Name=tag:Name,Values=ecs-lab-vpc" --query 'Vpcs[].VpcId' --output text`
inline (empty = clean), and run `bash scripts/preflight.sh` to delete anything found.

## Catch-up                      ← every lab except the first
terraform apply + catchup.sh, and the verification that proves they worked.

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
- **Fluent Bit in catch-ups:** from the logging lab on, containers use the `fluentd` log driver, and Docker refuses to start a container whose log driver can't connect. Every later catch-up must start Fluent Bit on the nodes even when `obs-01` isn't provisioned (it just retries the ES output).

---

## Lessons learned

*(Append here whenever a real Poridhi run breaks something: what failed, why, and the fix.)*

- **A failed `cd` doesn't stop a pasted block** (Lab 00). The rest of the paste ran in the wrong directory; `terraform init` "succeeded" in an empty folder and `apply` said "No configuration files". Fix: never assume the repo path; set a variable once (`KIT=$(pwd)`) and chain `cd DIR && cmd`, or put `cd` in its own block.
- **`describe-regions --query 'Regions[0].RegionName'` prints `ap-south-1`**, not the configured region: it's just the first region in the list. It looks like a misconfiguration to students. Use `aws ec2 describe-availability-zones --query 'AvailabilityZones[0].ZoneName' --output text` (prints `ap-southeast-1a`) as the EC2 credential probe.
- **The workspace has no `rsync`** (Lab 00). `push.sh` uses `tar | ssh tar` instead.
- **Time-sensitive observations must start in the same block as the action** (Lab 01). "Stop the agent" and "watch the registry" were separate blocks; on the real run the watch began ~65 s later and `node-02` was already `offline`, so the transition was never seen. Put the trigger and the watch loop in one block.
- **`docker compose up` in a non-TTY ssh session prints hundreds of `Extracting` / `Pull complete` lines** on the first image pull (Lab 01). Harmless; tell students to expect it and show only the tail in the doc.
- ✅ **Fixed private IPs work** (Lab 01): with `private_ip` set, agents registered as `10.0.1.21` / `10.0.1.22`.

---

## Current state

Lab 00 done (results in PORIDHI_PLATFORM.md). Lab 01 done: tested end to end on Poridhi; the doc (`docs/labs/lab-01-control-plane/README.md`) has only real output, and its code blocks match `main.py`/`agent.py` byte for byte. Branches: `lab-01-start` (= `main` minus `control-plane/main.py`, `agent/agent.py` and author-only files) and `lab-01-solution` (= start + those two files).

Lab 02: solution on `main` (`control-plane/main.py` tenant section, `agent/network.py`, agent API in `agent/agent.py`, `catchup.sh` re-creates alpha/beta, `verify.sh` checks tunnels). Tested locally with fakes (subnet split, specs sent to agents, idempotent re-run, token check), not yet on Poridhi. Doc at `docs/labs/lab-02-vxlan/README.md`; its edit steps were checked by applying them to the `lab-01-solution` files, which reproduces the new files exactly. Branch `lab-02-start` = `lab-01-solution` + the two new `requirements.txt` (its `catchup.sh`/`verify.sh` stay at the Lab 01 versions on purpose: they restore the *previous* lab's end state). Next: Adid runs the Lab 02 doc on Poridhi; then fill real output and cut `lab-02-solution`.
