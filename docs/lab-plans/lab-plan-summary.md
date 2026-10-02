# Build Your Own ECS: Lab Plan Summary

**Course:** Build Your Own ECS: Multi-Tenant Container Orchestration (Python track)
**Final exam:** Build a Multi-Tenant Agent Cloud with SSO and Centralized Logging
**Plan:** 7 labs on the Poridhi VS Code workspace + temporary AWS account

Every lab ships two things: a **student-facing lab document** and a **reference solution tested on a real Poridhi environment**. Students clone a per-lab branch of [poridhioss/ecs-lab](https://github.com/poridhioss/ecs-lab) and build on the previous lab's code. Each lab after the first opens with a scripted catch-up that rebuilds the previous lab's cluster in a few minutes.

---

## Lab 1: Building the Control Plane and Registering Agents

**Goal:** Stand up the cluster and its central control plane, and build the agent that runs on every compute node. Agents register themselves, then send heartbeats with their free capacity; silent agents are marked offline.

**Deliverables:**
- Terraform for the cluster: `control-01`, `node-01`, `node-02`, network and firewall
- Postgres and Temporal running on `control-01`
- FastAPI control plane with an agent registry (register, heartbeat, list, offline detection)
- Python agent on both nodes, running as a system service
- Deploy, verify and cleanup scripts reused by every later lab

## Lab 2: Isolating Tenants with a VXLAN Overlay Network

**Goal:** Give each tenant its own private network spanning both nodes. Containers of the same tenant can reach each other across machines; containers of different tenants cannot reach each other at all.

**Deliverables:**
- Tenant network allocation in the control plane (VXLAN ID and subnet per tenant)
- Agent code that builds each tenant's network on its node (Docker bridge + VXLAN tunnel to the other node)
- Demonstrated isolation: tenant `alpha` reaches `alpha` across nodes; `beta` cannot reach `alpha`

## Lab 3: Managing Container Lifecycles with Temporal

**Goal:** Launch tenant containers through durable Temporal workflows that place each container on a suitable node, monitor its health, and stop it automatically on failure or when its time-to-live expires.

**Deliverables:**
- `POST /containers` API with simple scheduling (the online node with the most free memory)
- Container lifecycle workflow: launch, periodic health checks, auto-termination
- Temporal workers: workflows on the control plane, container actions on each node's agent
- Visible lifecycles in the Temporal UI; container statuses tracked in Postgres

## Lab 4: Centralized Logging with Fluent Bit and Elasticsearch

**Goal:** Collect every container's logs from every node into one searchable store, tagged with tenant, container and node.

**Deliverables:**
- Elasticsearch and Kibana on a dedicated machine (`obs-01`)
- Fluent Bit on each node, shipping container logs to Elasticsearch
- Log records carrying `tenant_id`, `container_id` and `node_id`
- One Kibana view per tenant showing only that tenant's logs

## Lab 5: Monitoring the Cluster with Prometheus and Grafana

**Goal:** Make the cluster observable: each agent exposes metrics, Prometheus collects them, and Grafana shows them on a dashboard.

**Deliverables:**
- Agent `/metrics` endpoint (free CPU, free memory, active containers per tenant)
- Node Exporter on both nodes
- Prometheus and Grafana on `control-01`, with the data source and dashboard provisioned from files

## Lab 6: Multi-Tenant SSO with Authentik

**Goal:** Put identity in front of the control plane. Users log in through Authentik, belong to a tenant group, and every API request is checked against their token and scoped to their own tenant.

**Deliverables:**
- Authentik on a dedicated machine (`auth-01`), configured entirely by script: tenant groups, users `alice` (alpha) and `bob` (beta), OAuth/OpenID application
- Token verification in the control plane; the tenant always comes from the token, never from the request
- Enforced rules: no token → `401`, another tenant's resource → `403`

## Lab 7: Real-Time Log Streaming and the Tenant Web UI (Capstone)

**Goal:** Stream container logs to the browser live, and bring the whole platform together in a web page where a logged-in user sees only their own tenant's containers, status, metrics and logs.

**Deliverables:**
- Agent log publisher (container logs → Redis channel per container)
- Server-Sent Events endpoint for live logs, checked against the user's tenant
- Historical-logs endpoint backed by Elasticsearch, filtered by tenant
- Single-page web UI: Authentik login, container list, metrics, historical and live logs
- End-to-end demo: Alice and Bob each see only their own data

---

## Coverage of the exam's evaluation criteria

| Evaluation criterion | Covered in |
|---|---|
| Auth and multi-tenancy isolation | Labs 2, 6 |
| Agent registration and container deployment | Labs 1, 3 |
| Log data structure in Elasticsearch | Lab 4 |
| Temporal integration with clear workflows | Lab 3 |
| Prometheus metrics endpoint and Grafana dashboard | Lab 5 |
| Tenant-isolated web interface | Lab 7 |
| SSE log streaming tied to tenant/container | Lab 7 |
