"""Tenant networks on one node.

Each tenant gets a Docker bridge network (its private switch on this node),
and a VXLAN tunnel plugged into that bridge which carries the tenant's traffic
to the same bridge on the other nodes. Every step checks before it acts, so
running setup_tenant_network twice changes nothing the second time.
"""
import subprocess

import docker

client = docker.from_env()


def run(*cmd):
    """Run a command; if it fails, raise with its error message."""
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd)}: {result.stderr.strip()}")
    return result.stdout


def link_exists(name):
    return subprocess.run(["ip", "link", "show", name], capture_output=True).returncode == 0


def ensure_docker_network(tenant_id, spec, bridge):
    """The tenant's bridge, with this node's slice of the subnet and its own gateway."""
    try:
        client.networks.get(tenant_id)
        return []
    except docker.errors.NotFound:
        pass
    ipam = docker.types.IPAMConfig(pool_configs=[
        docker.types.IPAMPool(subnet=spec.subnet, iprange=spec.ip_range, gateway=spec.gateway)
    ])
    client.networks.create(
        tenant_id,
        driver="bridge",
        ipam=ipam,
        options={"com.docker.network.bridge.name": bridge},  # a name we choose, not br-<random>
        labels={"tenant_id": tenant_id},
    )
    return [f"created Docker network {tenant_id} (bridge {bridge}, range {spec.ip_range}, gateway {spec.gateway})"]


def ensure_vxlan(spec, vxlan, bridge, nic):
    """The tunnel device, plugged into the tenant's bridge."""
    changes = []
    if not link_exists(vxlan):
        # id: the tenant's VXLAN number (VNI). dstport 4789: the standard VXLAN UDP port.
        # dev: send tunnel packets out of the node's real NIC.
        # nolearning: don't guess where MAC addresses live; we list the peers ourselves.
        run("ip", "link", "add", vxlan, "type", "vxlan", "id", str(spec.vxlan_id),
            "dstport", "4789", "dev", nic, "nolearning")
        changes.append(f"created {vxlan} (VNI {spec.vxlan_id} via {nic})")
    run("ip", "link", "set", vxlan, "master", bridge)
    run("ip", "link", "set", vxlan, "up")
    return changes


def ensure_peers(vxlan, peers):
    """One all-zeros FDB entry per peer node: 'also send flooded traffic to this node'."""
    fdb = run("bridge", "fdb", "show", "dev", vxlan)
    changes = []
    for peer in peers:
        if f"dst {peer} " not in fdb:
            run("bridge", "fdb", "append", "00:00:00:00:00:00", "dev", vxlan, "dst", peer)
            changes.append(f"added peer {peer}")
    return changes


def setup_tenant_network(tenant_id, spec, nic):
    """Make this node's part of the tenant network match spec. Returns what it changed."""
    bridge, vxlan = f"br-{tenant_id}", f"vxlan{spec.vxlan_id}"
    return (
        ensure_docker_network(tenant_id, spec, bridge)
        + ensure_vxlan(spec, vxlan, bridge, nic)
        + ensure_peers(vxlan, spec.peers)
    )
