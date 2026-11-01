# LocalNode — VDS hosting on bare Ubuntu/KVM for FeatherPanel

LocalNode lets FeatherPanel manage VDS instances on a **local Ubuntu host with KVM/libvirt**, without requiring Proxmox.

It preserves existing GameNode, WebNode, and Proxmox VmNode behaviour: LocalNode is an additional **driver** on `featherpanel_vm_nodes`.

---

## Architecture

```
┌─────────────────────┐         HTTPS + Bearer token        ┌──────────────────────┐
│  FeatherPanel       │ ──────────────────────────────────► │  LocalNode Agent     │
│  (PHP API + React)  │                                     │  (FastAPI + libvirt) │
│  Admin → VDS → Nodes│                                     │  Ubuntu + KVM        │
└─────────────────────┘                                     └──────────┬───────────┘
                                                                       │
                                                              libvirt / QEMU-KVM
                                                                       │
                                                              ┌────────▼───────────┐
                                                              │  VDS instances     │
                                                              │  (qcow2 + VNC)     │
                                                              └────────────────────┘
```

| Component | Path | Role |
|-----------|------|------|
| Agent | `agent/` | Python FastAPI service on the KVM host |
| Installer | `scripts/local.sh` | One-shot Ubuntu setup + systemd |
| Migration | `panel/migrations/*.sql` | `driver`, `agent_token`, capacity fields |
| Panel client | `panel/backend/Services/LocalNodeClient.php` | Talks to agent |
| Admin API | `panel/backend/Controllers/LocalNodeController.php` | CRUD / power / console |
| UI fields | `panel/frontend/vds-nodes/LocalNodeFields.tsx` | Create/edit node form |

---

## Quick start (KVM host)

```bash
# On a fresh Ubuntu 22.04/24.04 server with nested virt or bare metal
cd /path/to/localnode
sudo bash scripts/local.sh
# Note the printed Token and Agent URL
```

Optional flags:

```bash
sudo bash scripts/local.sh --token 'your-secret' --port 8443 --bridge virbr0
```

Verify:

```bash
curl -s http://127.0.0.1:8443/health
curl -s -H "Authorization: Bearer <TOKEN>" http://127.0.0.1:8443/api/v1/host | jq
```

---

## Panel integration checklist

1. **Database**  
   Run `panel/migrations/2026-11-01.00.00-localnode.sql` via your normal migration runner.

2. **Backend**  
   - Copy `LocalNodeClient.php` → `backend/app/Services/`  
   - Copy `LocalNodeController.php` → `backend/app/Controllers/Admin/`  
   - Register routes (example):

```php
// backend/app/routes/admin/vm-nodes-local.php (include from main router)
$router->get('/api/admin/vm-nodes/{id}/local/host', [LocalNodeController::class, 'host']);
$router->get('/api/admin/vm-nodes/{id}/local/instances', [LocalNodeController::class, 'listInstances']);
$router->post('/api/admin/vm-nodes/{id}/local/instances', [LocalNodeController::class, 'createInstance']);
$router->post('/api/admin/vm-nodes/{id}/local/instances/{uuid}/{action}', [LocalNodeController::class, 'power']);
$router->delete('/api/admin/vm-nodes/{id}/local/instances/{uuid}', [LocalNodeController::class, 'deleteInstance']);
$router->get('/api/admin/vm-nodes/{id}/local/instances/{uuid}/console', [LocalNodeController::class, 'console']);
```

3. **VmNode model**  
   Add `driver`, `agent_token`, `host_*`, `kvm_available`, `last_heartbeat_at` to the `$allowedFields` whitelist in `App\Chat\VmNode`.

4. **VmNodesController create/update**  
   Accept `driver` (`proxmox`|`localnode`). When `localnode`, require `agent_token` instead of Proxmox `token_id`/`secret`.

5. **Frontend**  
   - Add driver select on create/edit node pages.  
   - When LocalNode, show `<LocalNodeFields />`.  
   - Optional host-info panel that calls `/local/host` after save.

6. **Instance provisioning path**  
   Where the panel currently calls Proxmox to create a VM, branch on `$node['driver'] === 'localnode'` and call `LocalNodeClient::createInstance()` + store `local_uuid` on the instance row.

7. **Permissions**  
   Reuse existing `admin.vm-nodes.*` / VDS permissions; no new gates required for MVP.

---

## Agent API (summary)

| Method | Path | Description |
|--------|------|-------------|
| GET | `/health` | Liveness (no auth) |
| GET | `/api/v1/host` | CPU/RAM/disk/KVM detection + usage |
| GET | `/api/v1/instances` | List VMs |
| POST | `/api/v1/instances` | Create (name, vcpus, memory_mb, disk_gb, iso?) |
| GET | `/api/v1/instances/{uuid}` | Status + stats |
| POST | `.../start` `.../stop` `.../restart` | Power |
| DELETE | `/api/v1/instances/{uuid}` | Delete |
| GET | `.../console` | VNC port info |
| GET | `/api/v1/isos` | ISO library under `/var/lib/localnode/iso` |

Auth: `Authorization: Bearer <token>` or `X-LocalNode-Token`.

---

## Security notes

- Change the agent token immediately if the install log is shared.
- Prefer HTTPS (put Caddy/nginx in front of port 8443) for production.
- Restrict agent port with firewall to the panel IP only.
- Agent runs as root (libvirt/qemu needs privileges); harden the host.

---

## What is **not** full parity with Proxmox yet

- Snapshots / backups (hook to `qemu-img` + schedule later)
- Cloud-init network injection
- Full noVNC proxy from panel (console currently returns VNC host:port)
- LXC containers
- Live migration

These can be added on the same agent without changing the panel driver contract.

---

## Testing workflow

1. Install agent with `local.sh` on a KVM host.  
2. Confirm `/api/v1/host` shows `kvm_available: true`.  
3. Create a LocalNode in Admin → VDS → Nodes.  
4. Create an instance via API or UI (1 vCPU, 1024 MB, 10 GB).  
5. Start → check `virsh list`.  
6. Console → connect VNC client to returned port.  
7. Stop / restart / delete and verify disk cleanup under `/var/lib/localnode/instances`.

---

## License

Same as your FeatherPanel fork (AGPL-3.0 recommended for compatibility with upstream).
