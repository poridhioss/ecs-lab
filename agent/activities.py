"""Container operations: the activities this node's Temporal worker runs.

The lifecycle workflow (on control-01) decides *what* happens and *when*;
these functions do the actual Docker work on this node. Each one is safe to
run again, because Temporal retries an activity if it fails or times out.
"""
import os

import docker
from temporalio import activity

NODE_ID = os.environ["NODE_ID"]
client = docker.from_env()


@activity.defn
def launch_container(spec: dict) -> dict:
    """Start the container on its tenant's network. A retry reuses an existing one."""
    name = spec["container_id"]
    try:
        container = client.containers.get(name)
    except docker.errors.NotFound:
        container = client.containers.run(
            spec["image"],
            spec["command"],
            name=name,
            detach=True,                         # start it and return; don't wait for it to finish
            network=spec["tenant_id"],           # the tenant's Docker network from the VXLAN lab
            labels={"tenant_id": spec["tenant_id"], "node_id": NODE_ID, "container_id": name},
            mem_limit=f"{spec['mem_mb']}m",
            nano_cpus=int(spec["cpu"] * 1_000_000_000),  # 1 CPU = 10^9 nano-CPUs
        )
    container.reload()  # refresh, so the network settings include the assigned IP
    ip = container.attrs["NetworkSettings"]["Networks"][spec["tenant_id"]]["IPAddress"]
    activity.logger.info("launched %s on %s at %s", name, NODE_ID, ip)
    return {"ip": ip}


@activity.defn
def check_container(container_id: str) -> dict:
    """Is the container still running? A missing container counts as unhealthy."""
    try:
        state = client.containers.get(container_id).attrs["State"]
    except docker.errors.NotFound:
        return {"healthy": False, "state": "missing"}
    return {"healthy": state["Running"], "state": state["Status"], "exit_code": state["ExitCode"]}


@activity.defn
def stop_container(container_id: str) -> str:
    """Stop and remove the container. Already gone counts as done."""
    try:
        container = client.containers.get(container_id)
    except docker.errors.NotFound:
        return "already gone"
    container.stop(timeout=5)  # SIGTERM, then SIGKILL after 5 seconds
    container.remove()
    activity.logger.info("removed %s", container_id)
    return "removed"
