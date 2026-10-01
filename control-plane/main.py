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
