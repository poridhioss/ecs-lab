"""Agent: runs on every compute node, like the ECS agent or the kubelet.

On start it registers the node with the control plane (who am I, what do I have,
how do I reach the network), then sends a heartbeat with its free capacity
every few seconds so the control plane knows it is alive.
"""
import asyncio
import logging
import os
import secrets
import socket

import httpx
import psutil
import uvicorn
from fastapi import Depends, FastAPI, Header, HTTPException
from pydantic import BaseModel

import network

NODE_ID = os.environ["NODE_ID"]                          # e.g. node-01, set by Terraform
CONTROL_PLANE = f"http://{os.environ['CONTROL_IP']}:8000"
HEADERS = {"X-Agent-Token": os.environ["AGENT_TOKEN"]}

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
log = logging.getLogger("agent")
logging.getLogger("httpx").setLevel(logging.WARNING)  # don't log every heartbeat request


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


# ---------- the agent's own API: the control plane calls it ----------

AGENT_PORT = 5050
api = FastAPI(title=f"ECS Lab Agent ({NODE_ID})")


def require_agent_token(x_agent_token: str = Header(default="")):
    """Only the control plane (which knows the shared token) may give orders."""
    if not secrets.compare_digest(x_agent_token, HEADERS["X-Agent-Token"]):
        raise HTTPException(status_code=401, detail="invalid agent token")


class NetworkSpec(BaseModel):
    vxlan_id: int       # the tenant's VXLAN number, e.g. 100
    subnet: str         # the whole tenant subnet, e.g. 10.10.1.0/24
    ip_range: str       # this node's half of it, e.g. 10.10.1.0/25
    gateway: str        # this node's gateway in that half, e.g. 10.10.1.1
    peers: list[str]    # private IPs of the other nodes


@api.put("/networks/{tenant_id}", dependencies=[Depends(require_agent_token)])
async def put_network(tenant_id: str, spec: NetworkSpec):
    # Runs shell commands and waits on Docker: do it on a thread, so heartbeats keep flowing.
    changes = await asyncio.to_thread(network.setup_tenant_network, tenant_id, spec, default_nic())
    log.info("tenant %s network: %s", tenant_id, "; ".join(changes) or "already up to date")
    return {"node_id": NODE_ID, "changes": changes}


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


async def heartbeats():
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


async def main():
    # Two jobs in one process: heartbeats in the background, the API in front.
    beating = asyncio.create_task(heartbeats())
    server = uvicorn.Server(uvicorn.Config(api, host="0.0.0.0", port=AGENT_PORT, log_level="warning"))
    await server.serve()  # runs until the service is stopped
    beating.cancel()


if __name__ == "__main__":
    asyncio.run(main())
