# Integrating LocalNode into FeatherPanel

Your fork (`adityazdomainzz-code/local-feather`) is currently empty. Recommended approach:

1. Fork or clone **MythicalLTD/FeatherPanel** (`develop` branch).
2. Copy the contents of this `localnode/` package into the tree.
3. Apply the small patches below.
4. Run migrations and deploy the agent with `scripts/local.sh`.

## 1. VmNode allowed fields

File: `backend/app/Chat/VmNode.php`

Add to `$allowedFields`:

```php
'driver',
'agent_token',
'host_cpu_threads',
'host_memory_mb',
'host_disk_gb',
'kvm_available',
'last_heartbeat_at',
```

In `validateVmNodeData`, allow:

```php
if (isset($data['driver']) && !in_array($data['driver'], ['proxmox', 'localnode'], true)) {
    $errors[] = 'Driver must be proxmox or localnode';
}
```

When creating a node, default `driver` to `proxmox` for backward compatibility.

## 2. Create/update node payload

In `VmNodesController` create/update handlers:

- If `driver === 'localnode'`:
  - Required: `name`, `location_id`, `fqdn`, `agent_token`
  - Optional: `scheme` (default http), `port` (default 8443), `tls_no_verify`, `timeout`
  - Do **not** require Proxmox `user` / `token_id` / `secret`
- Else keep existing Proxmox validation.

## 3. Instance create path

Wherever VMs are provisioned (typically user order flow or admin “create VDS”), branch:

```php
$node = VmNode::getById($nodeId);
if (($node['driver'] ?? 'proxmox') === 'localnode') {
    $client = new \App\Services\LocalNodeClient($node);
    $created = $client->createInstance([
        'name' => $name,
        'vcpus' => $vcpus,
        'memory_mb' => $memoryMb,
        'disk_gb' => $diskGb,
        'iso' => $isoName, // optional
    ]);
    // store $created['uuid'] as local_uuid on featherpanel_vm_instances
} else {
    // existing Proxmox flow
}
```

Power actions and console similarly branch to `LocalNodeClient`.

## 4. Frontend (frontendv2)

- `admin/vds-nodes/create/page.tsx` and edit tabs:
  - Add `driver` select.
  - Conditionally render Proxmox connection fields **or** `LocalNodeFields`.
- Instance detail / power buttons can call the `/local/...` admin routes when the parent node driver is `localnode`.

## 5. Preserve existing behaviour

- Default `driver = 'proxmox'` so all existing rows and UI keep working.
- Do not alter GameNode / WebNode code paths.
- Proxmox service class (`App\Services\Proxmox\Proxmox`) remains untouched.

## 6. Smoke test

```bash
# Host
sudo bash scripts/local.sh --token testtoken123
curl -H 'Authorization: Bearer testtoken123' http://127.0.0.1:8443/api/v1/host

# Panel DB
mysql ... < panel/migrations/2026-11-01.00.00-localnode.sql

# Create node via API with driver=localnode, then:
curl -H "Authorization: Bearer <panel-admin-jwt>" \
  https://panel/api/admin/vm-nodes/1/local/host
```
