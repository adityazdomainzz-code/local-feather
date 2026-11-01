"""
LocalNode libvirt/KVM manager.
Handles host detection, instance lifecycle, console, and resource accounting.
"""

from __future__ import annotations

import os
import re
import uuid
import json
import time
import shutil
import logging
import subprocess
from pathlib import Path
from typing import Any, Optional
from dataclasses import dataclass, asdict, field

import psutil

logger = logging.getLogger("localnode.libvirt")

try:
    import libvirt
except ImportError:
    libvirt = None  # type: ignore


@dataclass
class HostInfo:
    hostname: str
    cpu_model: str
    cpu_cores: int
    cpu_threads: int
    memory_total_mb: int
    memory_available_mb: int
    disk_total_gb: float
    disk_free_gb: float
    virtualization: str  # kvm, none, etc.
    kvm_available: bool
    libvirt_version: str
    qemu_version: str
    networks: list[str] = field(default_factory=list)
    storage_pools: list[dict] = field(default_factory=list)


@dataclass
class InstanceSpec:
    uuid: str
    name: str
    vcpus: int
    memory_mb: int
    disk_gb: int
    network: str = "default"
    os_type: str = "linux"
    iso: Optional[str] = None
    template: Optional[str] = None
    vnc_port: Optional[int] = None
    status: str = "stopped"
    created_at: float = 0.0
    metadata: dict = field(default_factory=dict)


class LibvirtManager:
    def __init__(self, config: dict):
        self.config = config
        self.uri = config.get("libvirt", {}).get("uri", "qemu:///system")
        self.bridge = config.get("libvirt", {}).get("bridge", "virbr0")
        self.pool_name = config.get("libvirt", {}).get("storage_pool", "localnode")
        paths = config.get("paths", {})
        self.data_dir = Path(paths.get("data_dir", "/var/lib/localnode"))
        self.images_dir = Path(paths.get("images_dir", str(self.data_dir / "images")))
        self.instances_dir = Path(paths.get("instances_dir", str(self.data_dir / "instances")))
        self.iso_dir = Path(paths.get("iso_dir", str(self.data_dir / "iso")))
        self.templates_dir = Path(paths.get("templates_dir", str(self.data_dir / "templates")))
        for d in (self.data_dir, self.images_dir, self.instances_dir, self.iso_dir, self.templates_dir):
            d.mkdir(parents=True, exist_ok=True)
        self._conn: Any = None
        self._instances: dict[str, InstanceSpec] = {}
        self._load_instances()

    # ── connection ──────────────────────────────────────────────

    def connect(self) -> None:
        if libvirt is None:
            raise RuntimeError("libvirt-python is not installed")
        if self._conn is None or not self._conn.isAlive():
            self._conn = libvirt.open(self.uri)
            if self._conn is None:
                raise RuntimeError(f"Failed to connect to libvirt at {self.uri}")
            logger.info("Connected to libvirt %s", self.uri)

    def disconnect(self) -> None:
        if self._conn:
            try:
                self._conn.close()
            except Exception:
                pass
            self._conn = None

    @property
    def conn(self):
        self.connect()
        return self._conn

    # ── host detection ──────────────────────────────────────────

    def get_host_info(self) -> HostInfo:
        hostname = os.uname().nodename
        cpu_model = "unknown"
        try:
            with open("/proc/cpuinfo") as f:
                for line in f:
                    if line.startswith("model name"):
                        cpu_model = line.split(":", 1)[1].strip()
                        break
        except OSError:
            pass

        mem = psutil.virtual_memory()
        disk = psutil.disk_usage(str(self.data_dir))

        virt = "none"
        kvm_available = False
        if Path("/dev/kvm").exists():
            kvm_available = True
            virt = "kvm"
        elif Path("/proc/cpuinfo").exists():
            with open("/proc/cpuinfo") as f:
                content = f.read()
                if "vmx" in content or "svm" in content:
                    virt = "hardware"

        libvirt_ver = "n/a"
        qemu_ver = "n/a"
        networks: list[str] = []
        pools: list[dict] = []
        try:
            self.connect()
            libvirt_ver = str(self.conn.getVersion())
            try:
                qemu_ver = subprocess.check_output(
                    ["qemu-system-x86_64", "--version"], text=True, timeout=5
                ).split("\n")[0]
            except Exception:
                pass
            for net in self.conn.listAllNetworks():
                networks.append(net.name())
            for pool in self.conn.listAllStoragePools():
                info = pool.info()
                pools.append({
                    "name": pool.name(),
                    "state": info[0],
                    "capacity_gb": round(info[1] / (1024**3), 2),
                    "allocation_gb": round(info[2] / (1024**3), 2),
                    "available_gb": round(info[3] / (1024**3), 2),
                })
        except Exception as e:
            logger.warning("Partial host info (libvirt unavailable): %s", e)

        return HostInfo(
            hostname=hostname,
            cpu_model=cpu_model,
            cpu_cores=psutil.cpu_count(logical=False) or 1,
            cpu_threads=psutil.cpu_count(logical=True) or 1,
            memory_total_mb=int(mem.total / (1024 * 1024)),
            memory_available_mb=int(mem.available / (1024 * 1024)),
            disk_total_gb=round(disk.total / (1024**3), 2),
            disk_free_gb=round(disk.free / (1024**3), 2),
            virtualization=virt,
            kvm_available=kvm_available,
            libvirt_version=libvirt_ver,
            qemu_version=qemu_ver,
            networks=networks,
            storage_pools=pools,
        )

    def resource_usage(self) -> dict:
        used_vcpus = sum(i.vcpus for i in self._instances.values() if i.status == "running")
        used_mem = sum(i.memory_mb for i in self._instances.values() if i.status == "running")
        used_disk = sum(i.disk_gb for i in self._instances.values())
        host = self.get_host_info()
        return {
            "vcpus_used": used_vcpus,
            "vcpus_total": host.cpu_threads,
            "memory_used_mb": used_mem,
            "memory_total_mb": host.memory_total_mb,
            "disk_used_gb": used_disk,
            "disk_free_gb": host.disk_free_gb,
            "instances_total": len(self._instances),
            "instances_running": sum(1 for i in self._instances.values() if i.status == "running"),
        }

    # ── persistence ─────────────────────────────────────────────

    def _instance_meta_path(self, inst_uuid: str) -> Path:
        return self.instances_dir / inst_uuid / "meta.json"

    def _load_instances(self) -> None:
        if not self.instances_dir.exists():
            return
        for d in self.instances_dir.iterdir():
            meta = d / "meta.json"
            if meta.is_file():
                try:
                    data = json.loads(meta.read_text())
                    spec = InstanceSpec(**{k: v for k, v in data.items() if k in InstanceSpec.__dataclass_fields__})
                    self._instances[spec.uuid] = spec
                except Exception as e:
                    logger.warning("Failed to load instance meta %s: %s", meta, e)

    def _save_instance(self, spec: InstanceSpec) -> None:
        inst_dir = self.instances_dir / spec.uuid
        inst_dir.mkdir(parents=True, exist_ok=True)
        self._instance_meta_path(spec.uuid).write_text(json.dumps(asdict(spec), indent=2))

    # ── domain XML ──────────────────────────────────────────────

    def _build_domain_xml(self, spec: InstanceSpec, disk_path: Path, iso_path: Optional[Path] = None) -> str:
        vnc_port = spec.vnc_port or -1
        iso_xml = ""
        if iso_path and iso_path.exists():
            iso_xml = f"""
    <disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source file='{iso_path}'/>
      <target dev='hda' bus='ide'/>
      <readonly/>
    </disk>"""
        return f"""<domain type='kvm'>
  <name>{spec.name}</name>
  <uuid>{spec.uuid}</uuid>
  <memory unit='MiB'>{spec.memory_mb}</memory>
  <currentMemory unit='MiB'>{spec.memory_mb}</currentMemory>
  <vcpu placement='static'>{spec.vcpus}</vcpu>
  <os>
    <type arch='x86_64' machine='pc-q35-8.2'>hvm</type>
    <boot dev='hd'/>
    <boot dev='cdrom'/>
  </os>
  <features>
    <acpi/>
    <apic/>
  </features>
  <cpu mode='host-passthrough' check='none'/>
  <clock offset='utc'/>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' cache='writeback'/>
      <source file='{disk_path}'/>
      <target dev='vda' bus='virtio'/>
    </disk>{iso_xml}
    <interface type='bridge'>
      <source bridge='{self.bridge}'/>
      <model type='virtio'/>
    </interface>
    <console type='pty'/>
    <graphics type='vnc' port='{vnc_port}' listen='0.0.0.0' passwd=''>
      <listen type='address' address='0.0.0.0'/>
    </graphics>
    <video>
      <model type='virtio' heads='1'/>
    </video>
    <memballoon model='virtio'/>
  </devices>
</domain>"""

    # ── lifecycle ───────────────────────────────────────────────

    def create_instance(
        self,
        name: str,
        vcpus: int,
        memory_mb: int,
        disk_gb: int,
        network: str = "default",
        iso: Optional[str] = None,
        template: Optional[str] = None,
        metadata: Optional[dict] = None,
    ) -> InstanceSpec:
        self.connect()
        host = self.get_host_info()
        if not host.kvm_available:
            raise RuntimeError("KVM is not available on this host")

        limits = self.config.get("limits", {})
        over_cpu = float(limits.get("overcommit_cpu", 2.0))
        over_mem = float(limits.get("overcommit_memory", 1.2))
        usage = self.resource_usage()
        if usage["vcpus_used"] + vcpus > host.cpu_threads * over_cpu:
            raise RuntimeError("CPU over-allocation limit reached")
        if usage["memory_used_mb"] + memory_mb > host.memory_total_mb * over_mem:
            raise RuntimeError("Memory over-allocation limit reached")
        if disk_gb > host.disk_free_gb - 5:
            raise RuntimeError("Insufficient free disk space")

        inst_uuid = str(uuid.uuid4())
        # sanitize name for libvirt
        safe_name = re.sub(r"[^a-zA-Z0-9._-]", "-", name)[:63] or f"vm-{inst_uuid[:8]}"

        inst_dir = self.instances_dir / inst_uuid
        inst_dir.mkdir(parents=True, exist_ok=True)
        disk_path = inst_dir / "disk.qcow2"

        # create disk
        if template:
            tpl = self.templates_dir / template
            if not tpl.exists():
                raise FileNotFoundError(f"Template not found: {template}")
            shutil.copy2(tpl, disk_path)
            # resize
            subprocess.check_call(
                ["qemu-img", "resize", str(disk_path), f"{disk_gb}G"],
                timeout=120,
            )
        else:
            subprocess.check_call(
                ["qemu-img", "create", "-f", "qcow2", str(disk_path), f"{disk_gb}G"],
                timeout=60,
            )

        iso_path = None
        if iso:
            candidate = self.iso_dir / iso
            if candidate.exists():
                iso_path = candidate
            elif Path(iso).exists():
                iso_path = Path(iso)

        # allocate VNC port (5900+)
        used_ports = {i.vnc_port for i in self._instances.values() if i.vnc_port}
        vnc_port = 5900
        while vnc_port in used_ports:
            vnc_port += 1

        spec = InstanceSpec(
            uuid=inst_uuid,
            name=safe_name,
            vcpus=vcpus,
            memory_mb=memory_mb,
            disk_gb=disk_gb,
            network=network,
            iso=iso,
            template=template,
            vnc_port=vnc_port,
            status="stopped",
            created_at=time.time(),
            metadata=metadata or {},
        )

        xml = self._build_domain_xml(spec, disk_path, iso_path)
        (inst_dir / "domain.xml").write_text(xml)
        self.conn.defineXML(xml)
        self._save_instance(spec)
        self._instances[inst_uuid] = spec
        logger.info("Created instance %s (%s)", safe_name, inst_uuid)
        return spec

    def _get_domain(self, inst_uuid: str):
        spec = self._instances.get(inst_uuid)
        if not spec:
            raise KeyError(f"Instance {inst_uuid} not found")
        try:
            return self.conn.lookupByUUIDString(inst_uuid)
        except libvirt.libvirtError:
            # try by name
            try:
                return self.conn.lookupByName(spec.name)
            except libvirt.libvirtError as e:
                raise KeyError(f"Domain not found in libvirt: {e}") from e

    def start_instance(self, inst_uuid: str) -> InstanceSpec:
        dom = self._get_domain(inst_uuid)
        if dom.isActive():
            self._instances[inst_uuid].status = "running"
            return self._instances[inst_uuid]
        dom.create()
        self._instances[inst_uuid].status = "running"
        self._save_instance(self._instances[inst_uuid])
        return self._instances[inst_uuid]

    def stop_instance(self, inst_uuid: str, force: bool = False) -> InstanceSpec:
        dom = self._get_domain(inst_uuid)
        if not dom.isActive():
            self._instances[inst_uuid].status = "stopped"
            return self._instances[inst_uuid]
        if force:
            dom.destroy()
        else:
            try:
                dom.shutdown()
                # wait up to 30s
                for _ in range(30):
                    time.sleep(1)
                    if not dom.isActive():
                        break
                else:
                    dom.destroy()
            except libvirt.libvirtError:
                dom.destroy()
        self._instances[inst_uuid].status = "stopped"
        self._save_instance(self._instances[inst_uuid])
        return self._instances[inst_uuid]

    def restart_instance(self, inst_uuid: str) -> InstanceSpec:
        self.stop_instance(inst_uuid)
        return self.start_instance(inst_uuid)

    def delete_instance(self, inst_uuid: str, force: bool = True) -> None:
        try:
            dom = self._get_domain(inst_uuid)
            if dom.isActive():
                if force:
                    dom.destroy()
                else:
                    raise RuntimeError("Instance is running; stop it first or use force")
            dom.undefine()
        except KeyError:
            pass
        except libvirt.libvirtError as e:
            logger.warning("libvirt undefine: %s", e)

        inst_dir = self.instances_dir / inst_uuid
        if inst_dir.exists():
            shutil.rmtree(inst_dir, ignore_errors=True)
        self._instances.pop(inst_uuid, None)
        logger.info("Deleted instance %s", inst_uuid)

    def get_instance(self, inst_uuid: str) -> InstanceSpec:
        if inst_uuid not in self._instances:
            raise KeyError(f"Instance {inst_uuid} not found")
        # refresh status
        try:
            dom = self._get_domain(inst_uuid)
            self._instances[inst_uuid].status = "running" if dom.isActive() else "stopped"
        except Exception:
            self._instances[inst_uuid].status = "unknown"
        return self._instances[inst_uuid]

    def list_instances(self) -> list[InstanceSpec]:
        result = []
        for uid in list(self._instances.keys()):
            try:
                result.append(self.get_instance(uid))
            except Exception:
                result.append(self._instances[uid])
        return result

    def get_console_info(self, inst_uuid: str) -> dict:
        spec = self.get_instance(inst_uuid)
        if spec.status != "running":
            raise RuntimeError("Instance is not running")
        return {
            "type": "vnc",
            "host": "0.0.0.0",
            "port": spec.vnc_port,
            "uuid": inst_uuid,
            "name": spec.name,
        }

    def instance_stats(self, inst_uuid: str) -> dict:
        try:
            dom = self._get_domain(inst_uuid)
            if not dom.isActive():
                return {"cpu_time": 0, "memory_kb": 0, "state": "stopped"}
            info = dom.info()
            # info: state, maxMem, memory, nrVirtCpu, cpuTime
            return {
                "state": info[0],
                "max_memory_kb": info[1],
                "memory_kb": info[2],
                "vcpus": info[3],
                "cpu_time_ns": info[4],
            }
        except Exception as e:
            return {"error": str(e)}
