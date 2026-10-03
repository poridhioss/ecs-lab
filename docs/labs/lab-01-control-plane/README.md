# Building the Control Plane and Registering Agents

## Overview

Over this course you will build a small cloud: a platform where several teams (tenants) launch containers on a shared pool of machines, each team isolated from the others. AWS ECS and Kubernetes work this way. This lab lays the foundation.

A cluster of machines is only useful if *something* knows which machines exist, how much room each one has, and which ones are still alive. Without that, you can't decide where a new container should go, and you won't notice when a machine dies.

Think of an **air traffic control tower**. Planes don't wait to be discovered: each one calls the tower when it enters the airspace ("this is flight 21, here's my position and fuel"), then reports in on a fixed schedule. If a plane goes silent for too long, the tower flags it. In our cluster:

- the **control plane** is the tower: one central service that keeps the registry of machines;
- each compute machine runs an **agent**, the plane's radio: it **registers** once at startup, then sends a **heartbeat** with its free capacity every 10 seconds;
- an agent that misses heartbeats for 30 seconds is marked **offline**.

This is exactly the "Agent Bootstrapping" part of the final exam (*Build a Multi-Tenant Agent Cloud*): agents register with the control plane, advertise capacity and network info, and keep sending heartbeats. Every later lab builds on the registry you create here. The scheduler will read it to place containers, and the workflows will send work to the agents it lists.

By the end of this lab you will have:

- three EC2 machines: `control-01`, `node-01` and `node-02`;
- Postgres and Temporal running on `control-01` (Temporal is the workflow engine a later lab uses to manage containers);
- a **FastAPI control plane** with an agent registry;
- a **Python agent** on both nodes, running as a system service.

## Architecture

```mermaid
flowchart LR
    subgraph WS["Workspace (Poridhi VS Code)"]
        TF["Terraform"]
        PUSH["scripts/push.sh"]
    end
    subgraph VPC["AWS VPC 10.0.0.0/16"]
        subgraph C["control-01 · 10.0.1.10"]
            CP["Control plane<br/>FastAPI :8000"]
            PG[("Postgres<br/>agents table")]
            TMP["Temporal :7233<br/>UI :8233"]
            CP --> PG
        end
        subgraph N1["node-01 · 10.0.1.21"]
            A1["Agent"]
        end
        subgraph N2["node-02 · 10.0.1.22"]
            A2["Agent"]
        end
        A1 -- "register, then heartbeat every 10s" --> CP
        A2 -- "register, then heartbeat every 10s" --> CP
    end
    TF -- "creates" --> VPC
    PUSH -- "ssh: copy code + install" --> C
    PUSH -- "ssh" --> N1
    PUSH -- "ssh" --> N2
    B["Your browser"] -- "public IP :8000, :8233" --> C
```

You work from the **workspace**. It creates the machines, holds the SSH key, and pushes code to them. You write code in VS Code on the workspace, then `scripts/push.sh` copies it to the right machine and (re)starts it.

## Before you start

### Get AWS credentials

Open **Cloud Tray → Credentials** and copy the **AccessKey** and **SecretKey**. On the **workspace** terminal:

**workspace**
```bash
aws configure
```

Paste the two keys, enter `ap-southeast-1` as the region, and press Enter for the output format. Then confirm that AWS accepts them:

**workspace**
```bash
aws sts get-caller-identity
aws ec2 describe-availability-zones --query 'AvailabilityZones[0].ZoneName' --output text
```

The first command prints your account and user. The second must print `ap-southeast-1a`. If it says `AuthFailure`, the new credentials haven't reached EC2 yet: wait a minute and run it again.

### Get the lab code

**workspace**
```bash
cd ~/code
git clone -b lab-01-start --depth 1 https://github.com/poridhioss/ecs-lab.git
cd ecs-lab && ls
```

`-b lab-01-start` checks out this lab's starting branch, and `--depth 1` downloads only its latest snapshot instead of the full history.

```
Cloning into 'ecs-lab'...
remote: Enumerating objects: 31, done.
remote: Counting objects: 100% (31/31), done.
remote: Compressing objects: 100% (30/30), done.
remote: Total 31 (delta 0), reused 29 (delta 0), pack-reused 0 (from 0)
Receiving objects: 100% (31/31), 10.08 KiB | 3.36 MiB/s, done.
agent  control-plane  infra  scripts
```

What you got:

| Path | What it is |
|---|---|
| `infra/terraform/` | Creates the network and the three machines |
| `infra/control/` | Docker Compose file for Postgres and Temporal |
| `control-plane/` | Install script, systemd unit and `requirements.txt`. **You write `main.py`.** |
| `agent/` | Install script, systemd unit and `requirements.txt`. **You write `agent.py`.** |
| `scripts/` | Helpers: `preflight.sh`, `push.sh`, `verify.sh`, `destroy.sh` |

### Check for leftovers

A cluster left behind by an earlier, unfinished session would clash with the one you're about to create. Check for one:

**workspace**
```bash
aws ec2 describe-vpcs --filters "Name=tag:Name,Values=ecs-lab-vpc" --query 'Vpcs[].VpcId' --output text
```

Empty output means the account is clean. If it prints a VPC ID, or just to be safe, run the cleanup script, which deletes the old VPC, its machines and the old SSH key:

**workspace**
```bash
bash scripts/preflight.sh
```

```
clean: no leftovers from an earlier session
```

## Concepts

### Control plane and agents

A cluster has two kinds of work. Deciding *what* should run *where* is the job of the **control plane**. Actually running it on a machine is the job of the **agent** on that machine. AWS ECS calls it the *ECS agent*, and Kubernetes calls it the *kubelet*. The control plane never touches a machine directly; it talks to agents.

### Registration vs heartbeat

**Registration** happens once, when the agent starts: "I am `node-01`, my IP is `10.0.1.21`, I have 2 CPUs and 4 GB of memory." It answers *who exists*.

A **heartbeat** repeats every few seconds: "I'm still here, and right now 1.7 CPUs and 3.1 GB are free." It answers *who is alive, and how busy*. Later, the scheduler will use this live free capacity to choose a machine for each new container.

### Detecting dead machines

A machine that crashes can't announce that it crashed. It simply goes quiet. So the control plane treats silence as the signal: if no heartbeat has arrived for **30 seconds** (three missed heartbeats), the agent is marked `offline`. One missed heartbeat could just be a slow network; three in a row almost certainly means trouble.

### Authenticating machines

Anyone who can reach port 8000 could register a fake node. So agent endpoints require a shared secret, the **agent token**, sent in an `X-Agent-Token` header. Agents are machines, not people, so they don't log in; they present the token. (People will authenticate differently, with single sign-on, in a later lab.) Terraform generates a fresh random token every time you create the cluster.

### Upsert: registering twice is fine

Agents restart: after a crash, a reboot, or a code update. When `node-01` registers again, the control plane should *update* its row, not fail with "already exists". Postgres does this in one statement: `INSERT ... ON CONFLICT (node_id) DO UPDATE`, often called an **upsert**. An operation you can safely repeat like this is called **idempotent**.

## Steps

### Step 1: Create the cluster

The Terraform configuration in `infra/terraform/` is provided. Here's what it creates:

| File | Creates |
|---|---|
| `network.tf` | A private network (VPC `10.0.0.0/16`) with one public subnet `10.0.1.0/24` and an internet gateway |
| `security.tf` | Firewall rules: SSH and ports 8000/8233 from anywhere, plus **all traffic between the cluster's own machines** |
| `keys.tf` | A new SSH key (saved to `~/.ssh/ecs-lab-key.id_rsa`) and a random agent token |
| `instances.tf` | The three machines, plus `~/.ssh/config` so you can type `ssh node-01` |
| `user_data.sh.tpl` | A script each machine runs on first boot: installs Docker and Python tools, writes `/etc/ecs-lab/ecs-lab.env` |

Each machine gets a **fixed private IP**, set in `variables.tf`:

```hcl
variable "machines" {
  default = {
    "control-01" = "10.0.1.10"
    "node-01"    = "10.0.1.21"
    "node-02"    = "10.0.1.22"
  }
}
```

`instances.tf` creates one machine per entry and asks AWS for that exact address:

```hcl
resource "aws_instance" "machine" {
  for_each   = var.machines   # one machine per entry in the map
  ...
  private_ip = each.value     # this exact address, not "any free one"
```

Without `private_ip`, AWS would pick any free address in the subnet. With it, AWS assigns exactly that address, or `terraform apply` fails with an error instead of quietly choosing another. These addresses are always free because every session starts with a brand-new, empty VPC. They are also all inside the subnet `10.0.1.0/24` and avoid the five addresses AWS reserves in every subnet (`.0` to `.3` and `.255`).

Because the addresses are fixed, every machine knows where the control plane is (`10.0.1.10`) before any of them exist. Only the *public* IPs change each time you create the cluster.

Create it:

**workspace**
```bash
cd ~/code/ecs-lab/infra/terraform && terraform init && terraform apply -auto-approve
```

`terraform init` downloads the providers (plugins for AWS, local files, keys and random values). `apply` creates everything, and `-auto-approve` skips the "are you sure?" prompt. It takes about a minute.

Terraform first prints its plan: every resource it will create, ending with `Plan: 14 to add, 0 to change, 0 to destroy.` In the plan, notice `private_ip = "10.0.1.10"` (and `.21`, `.22`) on the three machines. Then it creates them and prints the outputs:

```
aws_instance.machine["control-01"]: Creation complete after 12s [id=i-03060e2a129c5e186]
aws_instance.machine["node-01"]: Creation complete after 12s [id=i-0c4a05fc858121bbd]
aws_instance.machine["node-02"]: Creation complete after 12s [id=i-07ac791e5af1ea34d]
local_file.ssh_config: Creating...
local_file.ssh_config: Creation complete after 0s [id=deefd9ffd798387524c96aae791832ffda303e31]

Apply complete! Resources: 14 added, 0 changed, 0 destroyed.

Outputs:

agent_token = <sensitive>
control_public_ip = "52.77.230.138"
public_ips = {
  "control-01" = "52.77.230.138"
  "node-01" = "54.255.126.124"
  "node-02" = "13.215.153.252"
}
urls = {
  "control_plane" = "http://52.77.230.138:8000/agents"
  "temporal_ui" = "http://52.77.230.138:8233/"
}
```

Your public IPs and instance IDs will differ. The agent token shows as `<sensitive>` because Terraform hides secrets in its output.

Save the control plane's public IP and the agent token in shell variables. You'll use them throughout the lab:

**workspace**
```bash
cd ~/code/ecs-lab
CONTROL=$(terraform -chdir=infra/terraform output -raw control_public_ip)
TOKEN=$(terraform -chdir=infra/terraform output -raw agent_token)
echo "control plane: $CONTROL"
```

`-chdir=infra/terraform` runs Terraform as if you were in that folder, and `-raw` prints the bare value without quotes. If you open a new terminal later, run these three lines again.

```
control plane: 52.77.230.138
```

Each machine is still installing Docker in the background. Wait until all three report ready:

**workspace**
```bash
for m in control-01 node-01 node-02; do
  until ssh "$m" 'grep -q "BOOTSTRAP DONE" /var/log/bootstrap.log' 2>/dev/null; do sleep 5; done
  echo "$m ready"
done
```

The first-boot script writes `BOOTSTRAP DONE` at the end of its log, so this loop checks each machine every 5 seconds until it appears. Usually it's under a minute.

```
control-01 ready
node-01 ready
node-02 ready
```

**What now exists:** three Ubuntu machines with Docker installed. On each one, `/etc/ecs-lab/ecs-lab.env` holds that machine's settings:

**workspace**
```bash
ssh node-01 'sudo cat /etc/ecs-lab/ecs-lab.env'
```

```
NODE_ID=node-01
CONTROL_IP=10.0.1.10
AGENT_TOKEN=RydWD0asm6YRSw4d...
```

(Shortened here. Yours is a different random 32-character string, new every time you create the cluster.)

The agent will read these three values: its own name, where the control plane is, and the secret token. Terraform filled in `CONTROL_IP` from the same `machines` map, so it always matches the address `control-01` really has. Check it:

**workspace**
```bash
ssh control-01 'hostname; hostname -I'
```

`hostname -I` lists the machine's IP addresses. The first one is its private IP on the VPC (Docker's own internal address may follow it).

```
control-01
10.0.1.10 172.17.0.1
```

### Step 2: Start Postgres and Temporal

`infra/control/docker-compose.yml` runs two containers on `control-01`:

- **Postgres**, the control plane's database. It listens only on `127.0.0.1`, because only the control plane, on the same machine, needs it.
- **Temporal**, the workflow engine a later lab uses to manage container lifecycles. It runs as a single "dev server" container that includes its web UI on port 8233.

Deploy it with the push script:

**workspace**
```bash
bash scripts/push.sh infra
```

`push.sh infra` packs `infra/control/`, copies it over SSH to `/opt/ecs-lab/` on `control-01`, and runs its `install.sh` there. That runs `docker compose up -d --wait`: `-d` starts the containers in the background, and `--wait` blocks until they are running and Postgres reports healthy.

The first time, Docker downloads the two images and prints many `Extracting` and `Pull complete` lines. That's normal. The end of the output looks like this:

```
 Image temporalio/temporal:1.9.1 Pulled
 ...
 Image postgres:16 Pulled
 Network control_default Created
 Volume control_pgdata Created
 Volume control_temporaldata Created
 Container control-postgres-1 Created
 Container control-temporal-1 Created
 Container control-temporal-1 Started
 Container control-postgres-1 Started
 Container control-temporal-1 Healthy
 Container control-postgres-1 Healthy
waiting for the Temporal UI on :8233 ...
Postgres and Temporal are up
```

Open `http://CONTROL_IP:8233` in your browser, replacing `CONTROL_IP` with the value of `echo $CONTROL`. You should see the Temporal UI with an empty list of workflows. It stays empty until a later lab.

### Step 3: Write the control plane

In VS Code, create the file **`control-plane/main.py`** in `~/code/ecs-lab`. You'll build it in four parts; paste each part at the end of the file.

**Part 1: settings, the table, and database access.**

```python
"""Control plane: the cluster's brain.

For now it keeps a registry of agents (one per compute node): who they are,
what they have, and whether they are still alive.
"""
import asyncio
import logging
import os
import secrets
from contextlib import asynccontextmanager

import psycopg
from fastapi import Depends, FastAPI, Header, HTTPException
from psycopg.rows import dict_row
from pydantic import BaseModel

DATABASE_URL = os.environ.get("DATABASE_URL", "postgresql://ecs:ecs@localhost:5432/ecs")
AGENT_TOKEN = os.environ["AGENT_TOKEN"]
HEARTBEAT_INTERVAL = 10      # seconds between heartbeats, told to each agent
OFFLINE_AFTER = 30           # seconds of silence before an agent is marked offline

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
log = logging.getLogger("control-plane")

SCHEMA = """
CREATE TABLE IF NOT EXISTS agents (
    node_id       TEXT PRIMARY KEY,
    private_ip    TEXT NOT NULL,
    nic           TEXT NOT NULL,
    cpu_total     INTEGER NOT NULL,
    mem_total     BIGINT NOT NULL,
    cpu_free      REAL,
    mem_free      BIGINT,
    status        TEXT NOT NULL,
    registered_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen     TIMESTAMPTZ NOT NULL DEFAULT now()
);
"""


def db():
    """A new connection per call. `with db() as conn:` closes it afterwards."""
    return psycopg.connect(DATABASE_URL, autocommit=True, row_factory=dict_row)
```

One row per agent. `node_id` is the primary key, so each node appears exactly once. The `*_total` columns come from registration, the `*_free` columns from heartbeats, and `last_seen` records when we last heard from the agent. `AGENT_TOKEN` comes from the environment file Terraform wrote. `dict_row` makes query results come back as dictionaries (`row["node_id"]`), which FastAPI can return directly as JSON.

**Part 2: the offline checker, and the app itself.**

```python


# ---------- background task: mark silent agents offline ----------

def mark_offline():
    with db() as conn:
        rows = conn.execute(
            """UPDATE agents SET status = 'offline'
               WHERE status = 'online' AND last_seen < now() - make_interval(secs => %s)
               RETURNING node_id""",
            (OFFLINE_AFTER,),
        ).fetchall()
    for row in rows:
        log.warning("agent %s is offline (no heartbeat for %ss)", row["node_id"], OFFLINE_AFTER)


async def offline_checker():
    while True:
        try:
            await asyncio.to_thread(mark_offline)
        except Exception as e:  # keep checking even if the database blips
            log.error("offline check failed: %s", e)
        await asyncio.sleep(5)


@asynccontextmanager
async def lifespan(app):
    with db() as conn:
        conn.execute(SCHEMA)
    task = asyncio.create_task(offline_checker())
    yield
    task.cancel()


app = FastAPI(title="ECS Lab Control Plane", lifespan=lifespan)
```

Every 5 seconds, one SQL statement flips every `online` agent whose `last_seen` is more than 30 seconds old to `offline`. `RETURNING node_id` hands back the rows it changed, so we can log each one. `asyncio.to_thread` runs the (blocking) database call on a worker thread so it doesn't freeze the web server. `lifespan` is FastAPI's startup/shutdown hook: on startup it creates the table (if it doesn't exist yet) and starts the checker loop.

**Part 3: agent authentication and the request bodies.**

```python


# ---------- agent authentication ----------

def require_agent_token(x_agent_token: str = Header(default="")):
    """Agents are machines, not users: they prove who they are with a shared token."""
    if not secrets.compare_digest(x_agent_token, AGENT_TOKEN):
        raise HTTPException(status_code=401, detail="invalid agent token")


# ---------- request bodies ----------

class Registration(BaseModel):
    node_id: str
    private_ip: str
    nic: str
    cpu_total: int      # number of CPUs
    mem_total: int      # bytes


class Heartbeat(BaseModel):
    cpu_free: float     # idle CPUs, e.g. 1.6 of 2
    mem_free: int       # bytes available
```

FastAPI turns the parameter `x_agent_token` into the HTTP header `X-Agent-Token`. A missing or wrong token gets `401 Unauthorized`. `secrets.compare_digest` compares in constant time, so an attacker can't guess the token character by character from how long the comparison takes. The `BaseModel` classes describe the JSON each endpoint expects; a request with missing or wrongly typed fields is rejected with `422` before your code runs.

**Part 4: the endpoints.**

```python


# ---------- endpoints ----------

@app.get("/health")
def health():
    with db() as conn:
        conn.execute("SELECT 1")
    return {"status": "ok"}


@app.post("/agents/register", dependencies=[Depends(require_agent_token)])
def register(reg: Registration):
    # Upsert: a restarted agent registers again under the same node_id.
    with db() as conn:
        conn.execute(
            """INSERT INTO agents (node_id, private_ip, nic, cpu_total, mem_total, status)
               VALUES (%(node_id)s, %(private_ip)s, %(nic)s, %(cpu_total)s, %(mem_total)s, 'online')
               ON CONFLICT (node_id) DO UPDATE SET
                 private_ip = EXCLUDED.private_ip, nic = EXCLUDED.nic,
                 cpu_total = EXCLUDED.cpu_total, mem_total = EXCLUDED.mem_total,
                 status = 'online', registered_at = now(), last_seen = now()""",
            reg.model_dump(),
        )
    log.info("agent %s registered (%s via %s)", reg.node_id, reg.private_ip, reg.nic)
    return {"node_id": reg.node_id, "status": "registered", "heartbeat_interval": HEARTBEAT_INTERVAL}


@app.post("/agents/{node_id}/heartbeat", dependencies=[Depends(require_agent_token)])
def heartbeat(node_id: str, hb: Heartbeat):
    with db() as conn:
        updated = conn.execute(
            """UPDATE agents SET cpu_free = %s, mem_free = %s, status = 'online', last_seen = now()
               WHERE node_id = %s""",
            (hb.cpu_free, hb.mem_free, node_id),
        ).rowcount
    if updated == 0:
        # We don't know this agent (e.g. the database was reset): tell it to register again.
        raise HTTPException(status_code=404, detail="unknown agent, register first")
    return {"status": "ok"}


@app.get("/agents")
def list_agents():
    with db() as conn:
        return conn.execute(
            """SELECT node_id, status, private_ip, nic, cpu_total, cpu_free,
                      mem_total, mem_free, last_seen,
                      EXTRACT(EPOCH FROM now() - last_seen)::int AS seconds_since_seen
               FROM agents ORDER BY node_id"""
        ).fetchall()
```

Things to notice:

- `dependencies=[Depends(require_agent_token)]` runs the token check before each agent endpoint. `GET /agents` has no token for now; a later lab protects it with user logins.
- `register` is the upsert from the Concepts section. `EXCLUDED` means "the row you tried to insert". The response tells the agent how often to send heartbeats, so that setting lives in one place.
- `heartbeat` returns `404` if the node isn't registered (for example, if the database was wiped). The agent will react by registering again.
- `seconds_since_seen` is computed by Postgres, which makes the `offline` logic easy to watch.

Save the file.

### Step 4: Deploy the control plane and test it as a fake agent

**workspace**
```bash
bash scripts/push.sh control-plane
```

This copies `control-plane/` to `control-01`, creates a Python virtual environment at `/opt/ecs-lab/venv`, installs `requirements.txt` (FastAPI, Uvicorn, psycopg), installs `control-plane.service` as a systemd service, and waits until `/health` answers.

```
==> copied control-plane to control-01
waiting for the control plane on :8000 ...
control plane is up
```

The registry is empty:

**workspace**
```bash
curl -s http://$CONTROL:8000/agents; echo
```

`-s` hides curl's progress bar. `; echo` adds the newline the JSON doesn't end with.

```
[]
```

Before writing the real agent, act as one yourself. First, with a wrong token:

**workspace**
```bash
curl -s -w '\nHTTP %{http_code}\n' -X POST http://$CONTROL:8000/agents/register \
  -H "X-Agent-Token: wrong" -H "Content-Type: application/json" \
  -d '{"node_id": "fake-node", "private_ip": "10.0.1.99", "nic": "ens5", "cpu_total": 2, "mem_total": 4000000000}'
```

`-X POST` sends a POST, `-H` adds a header, `-d` is the request body, and `-w` prints the HTTP status code after the response.

```
{"detail":"invalid agent token"}
HTTP 401
```

Now with the real token:

**workspace**
```bash
curl -s -w '\nHTTP %{http_code}\n' -X POST http://$CONTROL:8000/agents/register \
  -H "X-Agent-Token: $TOKEN" -H "Content-Type: application/json" \
  -d '{"node_id": "fake-node", "private_ip": "10.0.1.99", "nic": "ens5", "cpu_total": 2, "mem_total": 4000000000}'
```

```
{"node_id":"fake-node","status":"registered","heartbeat_interval":10}
HTTP 200
```

`fake-node` is registered, but it will never send a heartbeat. Watch the control plane notice:

**workspace**
```bash
for i in $(seq 8); do
  curl -s http://$CONTROL:8000/agents | jq -r '.[] | "\(.node_id)  \(.status)  \(.seconds_since_seen)s"'
  sleep 5
done
```

`jq` reads JSON: `.[]` loops over the array, and `"\(.node_id)"` inserts a field into a string. `-r` prints plain text instead of JSON strings.

```
fake-node  online  17s
fake-node  online  22s
fake-node  online  27s
fake-node  online  32s
fake-node  offline  37s
fake-node  offline  42s
fake-node  offline  47s
fake-node  offline  52s
```

Your first number depends on how quickly you ran the loop after registering. Once the silence passes 30 seconds, the next run of the checker (every 5 seconds) turns `fake-node` `offline`. The control plane logged it:

**workspace**
```bash
ssh control-01 'journalctl -u control-plane -n 5 --no-pager'
```

`journalctl -u control-plane` shows that service's logs, `-n 5` the last five lines, and `--no-pager` prints them instead of opening a scrollable viewer.

```
Oct 03 15:19:38 control-01 uvicorn[4521]: INFO:     Uvicorn running on http://0.0.0.0:8000 (Press CTRL+C to quit)
Oct 03 15:19:39 control-01 uvicorn[4521]: INFO:     127.0.0.1:49174 - "GET /health HTTP/1.1" 200 OK
Oct 03 15:19:44 control-01 uvicorn[4521]: INFO agent fake-node registered (10.0.1.99 via ens5)
Oct 03 15:19:44 control-01 uvicorn[4521]: INFO:     103.191.50.64:55900 - "POST /agents/register HTTP/1.1" 200 OK
Oct 03 15:20:18 control-01 uvicorn[4521]: WARNING agent fake-node is offline (no heartbeat for 30s)
```

The lines starting `INFO:     ` (with spaces) are Uvicorn's request log; the others are from your code. Compare the timestamps: registered at `15:19:44`, marked offline at `15:20:18`, 34 seconds later. Your registration request shows the workspace's public IP, because `curl` ran there.

`fake-node` stays in the registry as an offline machine for the rest of the lab. That's fine; it shows what a dead node looks like.

### Step 5: Write the agent

In VS Code, create **`agent/agent.py`**. Again, paste each part at the end of the file.

**Part 1: settings.**

```python
"""Agent: runs on every compute node, like the ECS agent or the kubelet.

On start it registers the node with the control plane (who am I, what do I have,
how do I reach the network), then sends a heartbeat with its free capacity
every few seconds so the control plane knows it is alive.
"""
import asyncio
import logging
import os
import socket

import httpx
import psutil

NODE_ID = os.environ["NODE_ID"]                          # e.g. node-01, set by Terraform
CONTROL_PLANE = f"http://{os.environ['CONTROL_IP']}:8000"
HEADERS = {"X-Agent-Token": os.environ["AGENT_TOKEN"]}

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
log = logging.getLogger("agent")
logging.getLogger("httpx").setLevel(logging.WARNING)  # don't log every heartbeat request
```

The three values come from `/etc/ecs-lab/ecs-lab.env`, which you looked at in Step 1. The agent talks to the control plane's **private** IP: traffic between machines stays inside the VPC.

**Part 2: what the agent reports about its machine.**

```python


def default_nic():
    """The interface that carries the default route (ens5 on EC2). Never assume eth0."""
    with open("/proc/net/route") as f:
        for line in f.readlines()[1:]:
            iface, destination = line.split()[:2]
            if destination == "00000000":
                return iface
    raise RuntimeError("no default route")


def ipv4_of(nic):
    for addr in psutil.net_if_addrs()[nic]:
        if addr.family == socket.AF_INET:
            return addr.address
    raise RuntimeError(f"{nic} has no IPv4 address")


def registration():
    nic = default_nic()
    return {
        "node_id": NODE_ID,
        "private_ip": ipv4_of(nic),
        "nic": nic,
        "cpu_total": psutil.cpu_count(),
        "mem_total": psutil.virtual_memory().total,
    }


def capacity():
    # cpu_percent(interval=None) = usage since the previous call, so it never blocks
    idle_fraction = 1 - psutil.cpu_percent(interval=None) / 100
    return {
        "cpu_free": round(psutil.cpu_count() * idle_fraction, 2),
        "mem_free": psutil.virtual_memory().available,
    }
```

- **Network info.** `/proc/net/route` is the kernel's routing table. The row whose destination is `00000000` (that is, `0.0.0.0`) is the default route, and its interface is the machine's main network card. On EC2 that's `ens5`, not the `eth0` many tutorials assume. The tenant-network lab attaches virtual networks to this card, so the control plane needs to know its name and IP.
- **Capacity.** `psutil` reads CPU and memory stats. Free CPU is reported in CPUs: on a 2-CPU machine at 20% use, `cpu_free` is `1.6`. Free memory uses `available`, which counts memory the kernel can reclaim from caches, not just completely unused memory.

**Part 3: register, then heartbeat forever.**

```python


async def register(client):
    """Keep trying until the control plane accepts us. Returns the heartbeat interval."""
    body = registration()
    while True:
        try:
            r = await client.post("/agents/register", json=body)
            r.raise_for_status()
            log.info("registered as %s (%s via %s)", NODE_ID, body["private_ip"], body["nic"])
            return r.json()["heartbeat_interval"]
        except httpx.HTTPError as e:
            log.warning("registration failed (%s), retrying in 5s", e)
            await asyncio.sleep(5)


async def main():
    psutil.cpu_percent(interval=None)  # first call only sets the baseline
    async with httpx.AsyncClient(base_url=CONTROL_PLANE, headers=HEADERS, timeout=5) as client:
        interval = await register(client)
        while True:
            await asyncio.sleep(interval)
            try:
                r = await client.post(f"/agents/{NODE_ID}/heartbeat", json=capacity())
                if r.status_code == 404:  # the control plane forgot us: register again
                    interval = await register(client)
                    continue
                r.raise_for_status()
            except httpx.HTTPError as e:
                log.warning("heartbeat failed: %s", e)


if __name__ == "__main__":
    asyncio.run(main())
```

- `register` retries every 5 seconds until it succeeds. Agents often boot before the control plane is ready, so they should be patient rather than crash.
- The main loop sends a heartbeat every `interval` seconds (10, as the control plane said). A failed heartbeat is logged but doesn't stop the loop: the next one may well succeed.
- A `404` means the control plane doesn't know us any more, so we register again. Together with the upsert, this makes the system heal itself after either side restarts.
- The agent uses `asyncio` and `httpx`'s async client. That doesn't matter much yet, but in a later lab the agent also runs a Temporal worker in the same process, and both must share one event loop.

Save the file.

### Step 6: Deploy the agents

**workspace**
```bash
bash scripts/push.sh agent
```

For each node, this copies `agent/`, installs its requirements (`httpx`, `psutil`) into a virtual environment, and starts `agent.service`. The unit file runs the agent as root (a later lab has it create network interfaces) and restarts it automatically if it crashes (`Restart=always`).

```
==> copied agent to node-01
agent (re)started on node-01; logs: journalctl -u agent -f
==> copied agent to node-02
agent (re)started on node-02; logs: journalctl -u agent -f
```

Check what the agent on `node-01` logged:

**workspace**
```bash
ssh node-01 'journalctl -u agent -n 5 --no-pager'
```

```
Oct 03 12:58:05 node-01 systemd[1]: Started agent.service - ECS lab agent.
Oct 03 12:58:05 node-01 python[3617]: INFO registered as node-01 (10.0.1.21 via ens5)
```

And the registry:

**workspace**
```bash
curl -s http://$CONTROL:8000/agents | jq -r '.[] | "\(.node_id)  \(.status)  \(.private_ip)  cpu_free=\(.cpu_free)/\(.cpu_total)  last_seen=\(.seconds_since_seen)s ago"'
```

```
fake-node  offline  10.0.1.99  cpu_free=null/2  last_seen=210s ago
node-01  online  10.0.1.21  cpu_free=1.99/2  last_seen=5s ago
node-02  online  10.0.1.22  cpu_free=2.0/2  last_seen=7s ago
```

`cpu_free` is `null` until the first heartbeat arrives, 10 seconds after registration. `last_seen` never grows past 10 seconds for a live agent. You can also open `http://CONTROL_IP:8000/agents` in your browser to see the raw JSON, or `http://CONTROL_IP:8000/docs` for FastAPI's interactive API page.

## Break it on purpose

Kill an agent and watch the control plane notice. This block stops the agent on `node-02` and *immediately* starts watching the registry for 45 seconds. Paste it as one block: if you stop the agent first and start watching later, `node-02` may already be `offline` and you'll miss the change.

**workspace**
```bash
ssh node-02 'sudo systemctl stop agent'
for i in $(seq 9); do
  curl -s http://$CONTROL:8000/agents | jq -r '.[] | select(.node_id != "fake-node") | "\(.node_id)  \(.status)  \(.seconds_since_seen)s"'
  echo --
  sleep 5
done
```

`select(...)` filters out `fake-node` so you can focus on the real nodes.

```
node-01  online  6s
node-02  online  5s
--
node-01  online  1s
node-02  online  10s
--
node-01  online  6s
node-02  online  15s
--
node-01  online  1s
node-02  online  20s
--
node-01  online  6s
node-02  online  26s
--
node-01  online  1s
node-02  online  31s
--
node-01  online  6s
node-02  offline  36s
--
node-01  online  1s
node-02  offline  41s
--
node-01  online  6s
node-02  offline  46s
--
```

`node-01` keeps resetting to under 10 seconds, because its heartbeats keep arriving. `node-02` climbs past 30 and, at the next check, flips to `offline`. Now bring it back:

**workspace**
```bash
ssh node-02 'sudo systemctl start agent'
sleep 3
curl -s http://$CONTROL:8000/agents | jq -r '.[] | "\(.node_id)  \(.status)"'
```

```
fake-node  offline
node-01  online
node-02  online
```

`node-02` registered again on startup, and the upsert updated its existing row back to `online`.

## Verification

Run the lab's check script:

**workspace**
```bash
bash scripts/verify.sh
```

```
== control plane http://13.212.151.197:8000 ==
ok: /health
== agents (waiting up to 60s for 2 online) ==
fake-node  offline  10.0.1.99  cpu_free=null/2  mem_free=0 MiB
node-01  online  10.0.1.21  cpu_free=1.99/2  mem_free=3289 MiB
node-02  online  10.0.1.22  cpu_free=1.98/2  mem_free=3299 MiB
ok: 2 agents online
== Temporal UI ==
ok: http://13.212.151.197:8233/
ALL CHECKS PASSED
```

Your IP address and free-memory numbers will differ.

You're done when you see `ALL CHECKS PASSED`, and:

- both nodes are `online`, with their private IP, `ens5`, and live free capacity;
- a stopped agent turns `offline` within about 35 seconds and returns to `online` when restarted;
- the Temporal UI loads in your browser.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `AuthFailure` from an `aws ec2` command | New credentials haven't reached EC2 yet. Wait a minute and retry. |
| `InvalidClientTokenId` | Credentials from an old session. Copy fresh ones from Cloud Tray and run `aws configure` again. Also check `aws configure list` for stale `AWS_*` environment variables. |
| `terraform apply` fails with `InvalidKeyPair.Duplicate` | An `ecs-lab-key` from an earlier session still exists. Run `bash scripts/preflight.sh`, then apply again. |
| `push.sh`: `tar: /opt/ecs-lab: Cannot open: No such file or directory` | The machine's first-boot script hasn't finished. Rerun the "wait until ready" loop from Step 1. |
| `push.sh control-plane` ends with `control plane did not come up` | Usually a typo in `main.py`. Read the error: `ssh control-01 'journalctl -u control-plane -n 30 --no-pager'`. Fix the file, then `bash scripts/push.sh control-plane` again. |
| Agent log shows `registration failed (... 401 ...)` | Token mismatch. The control plane and agents both read `AGENT_TOKEN` from `/etc/ecs-lab/ecs-lab.env`; check that `main.py` uses the `X-Agent-Token` header name exactly. |
| Agent log shows `registration failed (... ConnectError ...)` | The control plane isn't running. Check it with `curl -s http://$CONTROL:8000/health`. |
| `curl` prints nothing, or `$CONTROL` is empty | You're in a new terminal. Rerun the three `CONTROL=` / `TOKEN=` lines from Step 1. |
| Temporal UI doesn't load | `ssh control-01 'cd /opt/ecs-lab/infra/control && docker compose logs --tail 20 temporal'` |
| Your code behaves differently from the lab | Compare with the reference solution: `git fetch --depth 1 origin lab-01-solution && git diff FETCH_HEAD -- control-plane/main.py agent/agent.py` |

## Cleanup

EC2 machines cost money every hour, so always finish by deleting everything. First make sure you're on the workspace: `hostname` should print a random string of letters and digits, not `control-01` or a node name.

**workspace**
```bash
hostname
cd ~/code/ecs-lab && bash scripts/destroy.sh
```

This runs `terraform destroy -auto-approve`, which deletes the machines, network, SSH key pair and token, and then checks that nothing is left.

Terraform first prints everything it will delete, ending with `Plan: 0 to add, 0 to change, 14 to destroy.` Deleting takes about a minute, mostly waiting for the machines to shut down. The output ends like this:

```
aws_instance.machine["control-01"]: Destruction complete after 31s
aws_instance.machine["node-02"]: Destruction complete after 31s
...
aws_vpc.main: Destroying... [id=vpc-0b9160d3c1e3e4cfe]
aws_vpc.main: Destruction complete after 1s

Destroy complete! Resources: 14 destroyed.
== leftover check: all three lists should be empty ==
running instances:
ecs-lab VPCs:
ecs-lab key pairs:
```

Nothing should be printed after the three headings. If something is, run `bash scripts/destroy.sh` again, or `bash scripts/preflight.sh` to delete leftovers by name.

## Summary

You built the foundation of the agent cloud:

- a **control plane** that keeps a registry of agents in Postgres and marks silent ones `offline` after 30 seconds;
- an **agent** on every node that registers itself with its network info and capacity, then sends a heartbeat every 10 seconds, and recovers on its own when either side restarts;
- token-based **machine authentication** on every agent endpoint;
- a repeatable workflow: Terraform creates the cluster, `push.sh` deploys code to it, `verify.sh` proves it works, `destroy.sh` removes it.

Right now every machine is just a box with free capacity. In the next lab, **Isolating Tenants with a VXLAN Overlay Network**, you give each tenant its own private network that stretches across both nodes, so one tenant's containers can talk to each other but never to another tenant's.
