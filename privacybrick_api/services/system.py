"""DietPi / system management.

Presented to the app as "Device": temperature, memory, disk, uptime, updates,
and a (confirmed-in-app) reboot.
"""

from __future__ import annotations

import re

from fastapi import APIRouter, Depends, HTTPException

from ..auth import require_token
from ..models import ActionResponse, ServiceHealth
from ..runner import CommandError, run

router = APIRouter(prefix="/system", tags=["system"], dependencies=[Depends(require_token)])


async def health() -> ServiceHealth:
    # If we can answer at all, the device is up.
    return ServiceHealth(id="system", name="Device", running=True, detail="online")


async def _cpu_temp_celsius() -> float | None:
    # Prefer vcgencmd on Raspberry Pi, fall back to sysfs thermal zone.
    try:
        result = await run(["vcgencmd", "measure_temp"])
        if result.ok:
            match = re.search(r"temp=([\d.]+)", result.stdout)
            if match:
                return float(match.group(1))
    except CommandError:
        pass
    try:
        result = await run(["cat", "/sys/class/thermal/thermal_zone0/temp"])
        if result.ok and result.stdout.strip().isdigit():
            return int(result.stdout.strip()) / 1000.0
    except CommandError:
        pass
    return None


@router.get("/info")
async def get_info() -> dict:
    hostname = await run(["hostname"])
    uptime = await run(["uptime", "-p"])
    mem = await run(["free", "-m"])
    disk = await run(["df", "-h", "/"])

    mem_total = mem_used = None
    for line in mem.stdout.splitlines():
        if line.startswith("Mem:"):
            parts = line.split()
            if len(parts) >= 3:
                mem_total, mem_used = int(parts[1]), int(parts[2])

    disk_percent = None
    lines = disk.stdout.splitlines()
    if len(lines) >= 2:
        parts = lines[1].split()
        if len(parts) >= 5:
            disk_percent = parts[4]

    dietpi_version = None
    try:
        version_file = await run(["cat", "/boot/dietpi/.version"])
        if version_file.ok:
            values = dict(
                line.partition("=")[::2] for line in version_file.stdout.splitlines() if "=" in line
            )
            core = values.get("G_DIETPI_VERSION_CORE", "").strip("'\"")
            sub = values.get("G_DIETPI_VERSION_SUB", "").strip("'\"")
            rc = values.get("G_DIETPI_VERSION_RC", "").strip("'\"")
            if core:
                dietpi_version = ".".join(v for v in (core, sub, rc) if v)
    except CommandError:
        pass

    return {
        "hostname": hostname.stdout.strip(),
        "uptime": uptime.stdout.strip().removeprefix("up ").strip(),
        "cpu_temp_celsius": await _cpu_temp_celsius(),
        "memory_total_mb": mem_total,
        "memory_used_mb": mem_used,
        "disk_used_percent": disk_percent,
        "dietpi_version": dietpi_version,
    }


@router.post("/reboot")
async def reboot() -> ActionResponse:
    """Reboot the Pi. The iOS app shows a confirmation dialog before calling."""
    try:
        result = await run(["shutdown", "-r", "+0"], timeout=10.0)
    except CommandError as exc:
        raise HTTPException(status_code=503, detail=str(exc))
    return ActionResponse(ok=result.ok, message="Rebooting…" if result.ok else result.output)
