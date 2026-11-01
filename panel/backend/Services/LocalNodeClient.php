<?php

/*
 * LocalNode agent HTTP client for FeatherPanel.
 * Talks to the Python LocalNode agent over HTTP/HTTPS with Bearer token auth.
 */

namespace App\Services;

use App\Chat\VmNode;

class LocalNodeClient
{
    private string $baseUrl;
    private string $token;
    private int $timeout;
    private bool $tlsNoVerify;

    public function __construct(array $node)
    {
        $scheme = $node['scheme'] ?? 'http';
        $fqdn = $node['fqdn'] ?? '127.0.0.1';
        $port = (int) ($node['port'] ?? 8443);
        $this->baseUrl = rtrim("{$scheme}://{$fqdn}:{$port}", '/');
        $this->token = (string) ($node['agent_token'] ?? $node['secret'] ?? '');
        $this->timeout = (int) ($node['timeout'] ?? 30);
        $this->tlsNoVerify = ($node['tls_no_verify'] ?? 'false') === 'true'
            || ($node['tls_no_verify'] ?? 0) == 1;
    }

    public static function fromNodeId(int $nodeId): self
    {
        $node = VmNode::getById($nodeId);
        if (!$node) {
            throw new \RuntimeException("VmNode {$nodeId} not found");
        }
        if (($node['driver'] ?? 'proxmox') !== 'localnode') {
            throw new \RuntimeException("Node {$nodeId} is not a LocalNode");
        }
        return new self($node);
    }

    private function request(string $method, string $path, ?array $body = null): array
    {
        $url = $this->baseUrl . $path;
        $ch = curl_init($url);
        $headers = [
            'Accept: application/json',
            'Content-Type: application/json',
            'Authorization: Bearer ' . $this->token,
            'X-LocalNode-Token: ' . $this->token,
        ];
        curl_setopt_array($ch, [
            CURLOPT_CUSTOMREQUEST => strtoupper($method),
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_TIMEOUT => $this->timeout,
            CURLOPT_HTTPHEADER => $headers,
            CURLOPT_SSL_VERIFYPEER => !$this->tlsNoVerify,
            CURLOPT_SSL_VERIFYHOST => $this->tlsNoVerify ? 0 : 2,
        ]);
        if ($body !== null) {
            curl_setopt($ch, CURLOPT_POSTFIELDS, json_encode($body));
        }
        $raw = curl_exec($ch);
        $code = (int) curl_getinfo($ch, CURLINFO_HTTP_CODE);
        $err = curl_error($ch);
        curl_close($ch);

        if ($raw === false) {
            throw new \RuntimeException("LocalNode request failed: {$err}");
        }
        $data = json_decode($raw, true);
        if ($code >= 400) {
            $detail = is_array($data) ? ($data['detail'] ?? $raw) : $raw;
            throw new \RuntimeException("LocalNode HTTP {$code}: {$detail}");
        }
        return is_array($data) ? $data : [];
    }

    public function health(): array
    {
        return $this->request('GET', '/health');
    }

    public function hostInfo(): array
    {
        return $this->request('GET', '/api/v1/host');
    }

    public function listInstances(): array
    {
        return $this->request('GET', '/api/v1/instances');
    }

    public function getInstance(string $uuid): array
    {
        return $this->request('GET', "/api/v1/instances/{$uuid}");
    }

    public function createInstance(array $params): array
    {
        return $this->request('POST', '/api/v1/instances', $params);
    }

    public function start(string $uuid): array
    {
        return $this->request('POST', "/api/v1/instances/{$uuid}/start");
    }

    public function stop(string $uuid, bool $force = false): array
    {
        return $this->request('POST', "/api/v1/instances/{$uuid}/stop", ['force' => $force]);
    }

    public function restart(string $uuid): array
    {
        return $this->request('POST', "/api/v1/instances/{$uuid}/restart");
    }

    public function delete(string $uuid, bool $force = true): array
    {
        $q = $force ? '?force=1' : '';
        return $this->request('DELETE', "/api/v1/instances/{$uuid}{$q}");
    }

    public function console(string $uuid): array
    {
        return $this->request('GET', "/api/v1/instances/{$uuid}/console");
    }

    public function listIsos(): array
    {
        return $this->request('GET', '/api/v1/isos');
    }
}
