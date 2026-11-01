<?php

/*
 * Admin API extensions for LocalNode.
 * Wire these routes alongside existing VmNodesController.
 *
 * Suggested routes (backend/app/routes/admin/...):
 *   GET    /api/admin/vm-nodes/{id}/local/host
 *   GET    /api/admin/vm-nodes/{id}/local/instances
 *   POST   /api/admin/vm-nodes/{id}/local/instances
 *   POST   /api/admin/vm-nodes/{id}/local/instances/{uuid}/start|stop|restart
 *   DELETE /api/admin/vm-nodes/{id}/local/instances/{uuid}
 *   GET    /api/admin/vm-nodes/{id}/local/instances/{uuid}/console
 */

namespace App\Controllers\Admin;

use App\App;
use App\Chat\VmNode;
use App\Chat\Activity;
use App\Helpers\ApiResponse;
use App\Services\LocalNodeClient;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;

class LocalNodeController
{
    private function nodeOrFail(int $id): array
    {
        $node = VmNode::getById($id);
        if (!$node) {
            throw new \RuntimeException('Node not found', 404);
        }
        if (($node['driver'] ?? 'proxmox') !== 'localnode') {
            throw new \RuntimeException('Not a LocalNode', 400);
        }
        return $node;
    }

    private function client(int $id): LocalNodeClient
    {
        return LocalNodeClient::fromNodeId($id);
    }

    private function audit(int $nodeId, string $action, ?string $uuid = null, ?array $detail = null): void
    {
        try {
            $pdo = App::getInstance(true)->getDatabase()->getPdo();
            $stmt = $pdo->prepare(
                'INSERT INTO featherpanel_localnode_audit (node_id, instance_uuid, actor_user_id, action, detail, ip)
                 VALUES (?, ?, ?, ?, ?, ?)'
            );
            $userId = $_SESSION['user']['id'] ?? null;
            $ip = $_SERVER['REMOTE_ADDR'] ?? null;
            $stmt->execute([
                $nodeId,
                $uuid,
                $userId,
                $action,
                $detail ? json_encode($detail) : null,
                $ip,
            ]);
        } catch (\Throwable $e) {
            // non-fatal
        }
    }

    public function host(Request $request, int $id): Response
    {
        try {
            $this->nodeOrFail($id);
            $data = $this->client($id)->hostInfo();

            // refresh cached capacity on node
            $host = $data['host'] ?? [];
            if ($host) {
                VmNode::update($id, [
                    'host_cpu_threads' => $host['cpu_threads'] ?? null,
                    'host_memory_mb' => $host['memory_total_mb'] ?? null,
                    'host_disk_gb' => (int) ($host['disk_total_gb'] ?? 0),
                    'kvm_available' => !empty($host['kvm_available']) ? 1 : 0,
                    'last_heartbeat_at' => date('Y-m-d H:i:s'),
                ]);
            }

            return ApiResponse::success($data);
        } catch (\Throwable $e) {
            $code = (int) $e->getCode();
            if ($code < 400 || $code > 599) {
                $code = 500;
            }
            return ApiResponse::error($e->getMessage(), $code);
        }
    }

    public function listInstances(Request $request, int $id): Response
    {
        try {
            $this->nodeOrFail($id);
            return ApiResponse::success($this->client($id)->listInstances());
        } catch (\Throwable $e) {
            return ApiResponse::error($e->getMessage(), 500);
        }
    }

    public function createInstance(Request $request, int $id): Response
    {
        try {
            $this->nodeOrFail($id);
            $body = json_decode($request->getContent(), true) ?: [];
            $required = ['name', 'vcpus', 'memory_mb', 'disk_gb'];
            foreach ($required as $f) {
                if (!isset($body[$f])) {
                    return ApiResponse::error("Missing field: {$f}", 400);
                }
            }
            $result = $this->client($id)->createInstance([
                'name' => $body['name'],
                'vcpus' => (int) $body['vcpus'],
                'memory_mb' => (int) $body['memory_mb'],
                'disk_gb' => (int) $body['disk_gb'],
                'network' => $body['network'] ?? 'default',
                'iso' => $body['iso'] ?? null,
                'template' => $body['template'] ?? null,
                'metadata' => $body['metadata'] ?? null,
            ]);
            $this->audit($id, 'instance.create', $result['uuid'] ?? null, $body);
            return ApiResponse::success($result, 201);
        } catch (\Throwable $e) {
            return ApiResponse::error($e->getMessage(), 500);
        }
    }

    public function power(Request $request, int $id, string $uuid, string $action): Response
    {
        try {
            $this->nodeOrFail($id);
            $client = $this->client($id);
            $result = match ($action) {
                'start' => $client->start($uuid),
                'stop' => $client->stop($uuid, (bool) ($request->query->get('force') ?? false)),
                'restart' => $client->restart($uuid),
                default => throw new \InvalidArgumentException('Invalid action'),
            };
            $this->audit($id, "instance.{$action}", $uuid);
            return ApiResponse::success($result);
        } catch (\Throwable $e) {
            return ApiResponse::error($e->getMessage(), 500);
        }
    }

    public function deleteInstance(Request $request, int $id, string $uuid): Response
    {
        try {
            $this->nodeOrFail($id);
            $result = $this->client($id)->delete($uuid, true);
            $this->audit($id, 'instance.delete', $uuid);
            return ApiResponse::success($result);
        } catch (\Throwable $e) {
            return ApiResponse::error($e->getMessage(), 500);
        }
    }

    public function console(Request $request, int $id, string $uuid): Response
    {
        try {
            $this->nodeOrFail($id);
            return ApiResponse::success($this->client($id)->console($uuid));
        } catch (\Throwable $e) {
            return ApiResponse::error($e->getMessage(), 500);
        }
    }
}
