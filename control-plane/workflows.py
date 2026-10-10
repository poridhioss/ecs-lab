"""The container lifecycle, as a Temporal workflow.

The workflow is the *plan*: launch the container, check its health every few
seconds until it fails or its time is up, then clean up. Temporal records every
step, so if the control plane restarts halfway, the workflow carries on exactly
where it was, timers included. The *work* (Docker calls) happens in activities,
which run on the agent of the node the container was scheduled on.
"""
import asyncio
from dataclasses import dataclass
from datetime import timedelta

from temporalio import workflow
from temporalio.common import RetryPolicy
from temporalio.exceptions import ActivityError

CHECK_EVERY = 15        # seconds between health checks
MAX_FAILED_CHECKS = 3   # this many failed checks in a row means the container has failed


@dataclass
class ContainerSpec:
    container_id: str
    tenant_id: str
    node_id: str
    image: str
    command: list[str] | None
    cpu: float
    mem_mb: int
    ttl_seconds: int


@workflow.defn
class ContainerLifecycleWorkflow:
    @workflow.run
    async def run(self, spec: ContainerSpec) -> str:
        # 1. Launch on the chosen node. Activities are called by name, on the node's
        #    task queue, so only that node's agent picks them up.
        try:
            launched = await workflow.execute_activity(
                "launch_container", spec,
                task_queue=spec.node_id,
                schedule_to_close_timeout=timedelta(minutes=3),  # includes pulling the image
                retry_policy=RetryPolicy(maximum_attempts=3),
            )
        except ActivityError as e:
            return await self.finish(spec, "failed", f"launch failed: {e.cause}")
        await self.record(spec, "running", ip=launched["ip"])

        # 2. Watch it until its time is up, or until it fails.
        deadline = workflow.now() + timedelta(seconds=spec.ttl_seconds)
        failed_checks = 0
        while workflow.now() < deadline:
            seconds_left = (deadline - workflow.now()).total_seconds()
            await asyncio.sleep(min(CHECK_EVERY, seconds_left))  # a durable timer
            if workflow.now() >= deadline:
                break
            if await self.is_healthy(spec):
                failed_checks = 0
            else:
                failed_checks += 1
                if failed_checks >= MAX_FAILED_CHECKS:
                    return await self.finish(spec, "failed", f"{MAX_FAILED_CHECKS} failed health checks in a row")

        # 3. Time's up.
        return await self.finish(spec, "expired", f"TTL of {spec.ttl_seconds}s reached")

    async def is_healthy(self, spec):
        try:
            health = await workflow.execute_activity(
                "check_container", spec.container_id,
                task_queue=spec.node_id,
                schedule_to_close_timeout=timedelta(seconds=10),  # a dead node never answers
                retry_policy=RetryPolicy(maximum_attempts=1),     # a failed check is a result, not an error
            )
        except ActivityError:
            workflow.logger.warning("health check for %s got no answer from %s", spec.container_id, spec.node_id)
            return False
        return health["healthy"]

    async def finish(self, spec, status, reason):
        """Remove the container (if its node answers) and record how it ended."""
        try:
            await workflow.execute_activity(
                "stop_container", spec.container_id,
                task_queue=spec.node_id,
                schedule_to_close_timeout=timedelta(seconds=30),
            )
        except ActivityError:
            reason += " (node did not answer, container not removed)"
        await self.record(spec, status, reason=reason)
        return status

    async def record(self, spec, status, ip=None, reason=None):
        # No task_queue: this activity runs on the workflow's own queue, on control-01.
        await workflow.execute_activity(
            "record_status",
            {"container_id": spec.container_id, "status": status, "ip": ip, "reason": reason},
            start_to_close_timeout=timedelta(seconds=10),
        )
