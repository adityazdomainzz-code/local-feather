/**
 * Drop-in form fields for LocalNode when creating/editing a VDS node.
 *
 * Integration guide (frontendv2):
 * 1. In admin/vds-nodes/create/page.tsx and [id]/edit pages, add a "Driver" select:
 *      proxmox | localnode
 * 2. When driver === 'localnode', render <LocalNodeFields /> instead of Proxmox token fields.
 * 3. On submit, send driver: 'localnode' and agent_token instead of token_id/secret.
 * 4. Optional: after create, call GET /api/admin/vm-nodes/{id}/local/host to validate connectivity.
 */

'use client';

import React from 'react';

export type LocalNodeFormValues = {
  driver: 'localnode';
  name: string;
  description?: string;
  location_id: number;
  fqdn: string;
  scheme: 'http' | 'https';
  port: number;
  agent_token: string;
  tls_no_verify: boolean;
  timeout: number;
};

type Props = {
  values: Partial<LocalNodeFormValues>;
  onChange: (patch: Partial<LocalNodeFormValues>) => void;
  disabled?: boolean;
};

export function LocalNodeFields({ values, onChange, disabled }: Props) {
  const v = {
    scheme: 'http' as const,
    port: 8443,
    timeout: 30,
    tls_no_verify: false,
    ...values,
  };

  return (
    <div className="space-y-4">
      <div className="rounded-lg border border-amber-500/30 bg-amber-500/5 p-3 text-sm">
        LocalNode uses a lightweight agent on a Ubuntu/KVM host (no Proxmox required).
        Install the agent with <code className="text-xs">bash local.sh</code> on the target server,
        then paste the generated token below.
      </div>

      <label className="block space-y-1">
        <span className="text-sm font-medium">Agent FQDN / IP</span>
        <input
          className="w-full rounded-md border bg-background px-3 py-2"
          value={v.fqdn ?? ''}
          disabled={disabled}
          onChange={(e) => onChange({ fqdn: e.target.value })}
          placeholder="vds-host.example.com"
        />
      </label>

      <div className="grid grid-cols-2 gap-3">
        <label className="block space-y-1">
          <span className="text-sm font-medium">Scheme</span>
          <select
            className="w-full rounded-md border bg-background px-3 py-2"
            value={v.scheme}
            disabled={disabled}
            onChange={(e) => onChange({ scheme: e.target.value as 'http' | 'https' })}
          >
            <option value="http">http</option>
            <option value="https">https</option>
          </select>
        </label>
        <label className="block space-y-1">
          <span className="text-sm font-medium">Port</span>
          <input
            type="number"
            className="w-full rounded-md border bg-background px-3 py-2"
            value={v.port}
            disabled={disabled}
            onChange={(e) => onChange({ port: Number(e.target.value) })}
          />
        </label>
      </div>

      <label className="block space-y-1">
        <span className="text-sm font-medium">Agent token</span>
        <input
          type="password"
          className="w-full rounded-md border bg-background px-3 py-2 font-mono text-sm"
          value={v.agent_token ?? ''}
          disabled={disabled}
          onChange={(e) => onChange({ agent_token: e.target.value })}
          placeholder="paste token from local.sh output"
          autoComplete="off"
        />
      </label>

      <label className="flex items-center gap-2 text-sm">
        <input
          type="checkbox"
          checked={!!v.tls_no_verify}
          disabled={disabled}
          onChange={(e) => onChange({ tls_no_verify: e.target.checked })}
        />
        Skip TLS certificate verification
      </label>
    </div>
  );
}

export default LocalNodeFields;
