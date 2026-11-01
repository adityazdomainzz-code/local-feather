"""
LocalNode Agent HTTP API
Exposes host info, instance lifecycle, console and resource endpoints
for FeatherPanel LocalNode integration.
"""

from __future__ import annotations

import os
import sys
import logging
from pathlib import Path
from typing import Any, Optional

import yaml
from fastapi import FastAPI, Depends, HTTPException, Header, Request, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

# ensure agent package is importable
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from libvirt.manager import LibvirtManager, InstanceSpec  # noqa: E402

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("localnode.api")

# ── config ──────────────────────────────────────────────────────

CONFIG_PATHS = [
    Path(os.environ.get("LOCALNODE_CONFIG", "")),
    Path("/etc/localnode/config.yaml"),
    Path(__file__).resolve().parents[1] / "config" / "config.yaml",
    Path(__file__).resolve().parents[1] / "config" / "config.example.yaml",
]


def load_config() -> dict:
    for p in CONFIG_PATHS:
        if p and p.is_file():
            with open(p) as f:
                cfg = yaml.safe_load(f) or {}
            logger.info("Loaded config from %s", p)
            return cfg
    logger.warning("No config found; using defaults")
    return {}


config = load_config()
manager = LibvirtManager(config)

app = FastAPI(
    title="LocalNode Agent",
    version="1.0.0",
    description="KVM/libvirt agent for FeatherPanel LocalNode VDS hosting",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# ── auth ────────────────────────────────────────────────────────

def verify_token(
    authorization: Optional[str] = Header(None),
    x_localnode_token: Optional[str] = Header(None),
) -> None:
    expected = config.get("auth", {}).get("token", "")
    if not expected or expected.startswith("CHANGE_ME"):
        # allow open access only if explicitly configured empty in non-prod
        if os.environ.get("LOCALNODE_ALLOW_INSECURE") == "1":
            return
        raise HTTPException(status_code=500, detail="Agent token not configured")
    token = None
    if authorization and authorization.lower().startswith("bearer "):
        token = authorization[7:].strip()
    elif x_localnode_token:
        token = x_localnode_token.strip()
    if token != expected:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token")


# ── models ──────────────────────────────────────────────────────

class CreateInstanceRequest(BaseModel):
    name: str = Field(..., min_length=1, max_length=63)
    vcpus: int = Field(..., ge=1, le=128)
    memory_mb: int = Field(..., ge=128, le=1048576)
    disk_gb: int = Field(..., ge=1, le=10240)
    network: str = "default"
    iso: Optional[str] = None
    template: Optional[str] = None
    metadata: Optional[dict[str, Any]] = None


class PowerAction(BaseModel):
    force: bool = False


# ── routes ──────────────────────────────────────────────────────

@app.get("/health")
def health():
    return {"status": "ok", "service": "localnode-agent"}


@app.get("/api/v1/host", dependencies=[Depends(verify_token)])
def get_host():
    try:
        info = manager.get_host_info()
        usage = manager.resource_usage()
        return {
            "host": {
                "hostname": info.hostname,
                "cpu_model": info.cpu_model,
                "cpu_cores": info.cpu_cores,
                "cpu_threads": info.cpu_threads,
                "memory_total_mb": info.memory_total_mb,
                "memory_available_mb": info.memory_available_mb,
                "disk_total_gb": info.disk_total_gb,
                "disk_free_gb": info.disk_free_gb,
                "virtualization": info.virtualization,
                "kvm_available": info.kvm_available,
                "libvirt_version": info.libvirt_version,
                "qemu_version": info.qemu_version,
                "networks": info.networks,
                "storage_pools": info.storage_pools,
            },
            "usage": usage,
        }
    except Exception as e:
        logger.exception("host info failed")
        raise HTTPException(500, str(e))


@app.get("/api/v1/instances", dependencies=[Depends(verify_token)])
def list_instances():
    try:
        items = manager.list_instances()
        return {
            "data": [
                {
                    "uuid": i.uuid,
                    "name": i.name,
                    "vcpus": i.vcpus,
                    "memory_mb": i.memory_mb,
                    "disk_gb": i.disk_gb,
                    "network": i.network,
                    "status": i.status,
                    "vnc_port": i.vnc_port,
                    "created_at": i.created_at,
                    "metadata": i.metadata,
                }
                for i in items
            ]
        }
    except Exception as e:
        raise HTTPException(500, str(e))


@app.post("/api/v1/instances", dependencies=[Depends(verify_token)], status_code=201)
def create_instance(body: CreateInstanceRequest):
    try:
        spec = manager.create_instance(
            name=body.name,
            vcpus=body.vcpus,
            memory_mb=body.memory_mb,
            disk_gb=body.disk_gb,
            network=body.network,
            iso=body.iso,
            template=body.template,
            metadata=body.metadata,
        )
        return {
            "uuid": spec.uuid,
            "name": spec.name,
            "vcpus": spec.vcpus,
            "memory_mb": spec.memory_mb,
            "disk_gb": spec.disk_gb,
            "status": spec.status,
            "vnc_port": spec.vnc_port,
        }
    except RuntimeError as e:
        raise HTTPException(400, str(e))
    except Exception as e:
        logger.exception("create failed")
        raise HTTPException(500, str(e))


@app.get("/api/v1/instances/{uuid}", dependencies=[Depends(verify_token)])
def get_instance(uuid: str):
    try:
        i = manager.get_instance(uuid)
        stats = manager.instance_stats(uuid)
        return {
            "uuid": i.uuid,
            "name": i.name,
            "vcpus": i.vcpus,
            "memory_mb": i.memory_mb,
            "disk_gb": i.disk_gb,
            "network": i.network,
            "status": i.status,
            "vnc_port": i.vnc_port,
            "created_at": i.created_at,
            "metadata": i.metadata,
            "stats": stats,
        }
    except KeyError:
        raise HTTPException(404, "Instance not found")
    except Exception as e:
        raise HTTPException(500, str(e))


@app.post("/api/v1/instances/{uuid}/start", dependencies=[Depends(verify_token)])
def start_instance(uuid: str):
    try:
        i = manager.start_instance(uuid)
        return {"uuid": i.uuid, "status": i.status}
    except KeyError:
        raise HTTPException(404, "Instance not found")
    except Exception as e:
        raise HTTPException(500, str(e))


@app.post("/api/v1/instances/{uuid}/stop", dependencies=[Depends(verify_token)])
def stop_instance(uuid: str, body: PowerAction = PowerAction()):
    try:
        i = manager.stop_instance(uuid, force=body.force)
        return {"uuid": i.uuid, "status": i.status}
    except KeyError:
        raise HTTPException(404, "Instance not found")
    except Exception as e:
        raise HTTPException(500, str(e))


@app.post("/api/v1/instances/{uuid}/restart", dependencies=[Depends(verify_token)])
def restart_instance(uuid: str):
    try:
        i = manager.restart_instance(uuid)
        return {"uuid": i.uuid, "status": i.status}
    except KeyError:
        raise HTTPException(404, "Instance not found")
    except Exception as e:
        raise HTTPException(500, str(e))


@app.delete("/api/v1/instances/{uuid}", dependencies=[Depends(verify_token)])
def delete_instance(uuid: str, force: bool = True):
    try:
        manager.delete_instance(uuid, force=force)
        return {"deleted": True, "uuid": uuid}
    except RuntimeError as e:
        raise HTTPException(400, str(e))
    except Exception as e:
        raise HTTPException(500, str(e))


@app.get("/api/v1/instances/{uuid}/console", dependencies=[Depends(verify_token)])
def console_info(uuid: str):
    try:
        return manager.get_console_info(uuid)
    except KeyError:
        raise HTTPException(404, "Instance not found")
    except RuntimeError as e:
        raise HTTPException(400, str(e))
    except Exception as e:
        raise HTTPException(500, str(e))


@app.get("/api/v1/isos", dependencies=[Depends(verify_token)])
def list_isos():
    iso_dir = manager.iso_dir
    items = []
    if iso_dir.exists():
        for f in sorted(iso_dir.iterdir()):
            if f.is_file() and f.suffix.lower() in (".iso", ".img"):
                items.append({"name": f.name, "size_mb": round(f.stat().st_size / (1024 * 1024), 1)})
    return {"data": items}


@app.exception_handler(Exception)
async def unhandled(request: Request, exc: Exception):
    logger.exception("Unhandled: %s", exc)
    return JSONResponse(status_code=500, content={"detail": str(exc)})


def run():
    import uvicorn
    host = config.get("server", {}).get("host", "0.0.0.0")
    port = int(config.get("server", {}).get("port", 8443))
    uvicorn.run("api.main:app", host=host, port=port, reload=False, log_level="info")


if __name__ == "__main__":
    run()
