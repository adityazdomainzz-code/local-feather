-- LocalNode support for FeatherPanel VDS
-- Extends featherpanel_vm_nodes with driver type and local-agent fields.
-- Safe to run multiple times (IF NOT EXISTS / ignore duplicate column errors in some DBs).

-- Node driver: proxmox (default) | localnode
ALTER TABLE `featherpanel_vm_nodes`
  ADD COLUMN IF NOT EXISTS `driver` VARCHAR(32) NOT NULL DEFAULT 'proxmox'
  COMMENT 'Hypervisor driver: proxmox | localnode' AFTER `name`;

-- Agent auth token (for LocalNode; Proxmox continues to use token_id/secret)
ALTER TABLE `featherpanel_vm_nodes`
  ADD COLUMN IF NOT EXISTS `agent_token` TEXT NULL
  COMMENT 'Bearer token for LocalNode agent API' AFTER `secret`;

-- Cached host capacity (updated by heartbeat / poll)
ALTER TABLE `featherpanel_vm_nodes`
  ADD COLUMN IF NOT EXISTS `host_cpu_threads` INT UNSIGNED NULL DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS `host_memory_mb` INT UNSIGNED NULL DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS `host_disk_gb` INT UNSIGNED NULL DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS `kvm_available` TINYINT(1) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS `last_heartbeat_at` TIMESTAMP NULL DEFAULT NULL;

-- Instance linkage for LocalNode (Proxmox uses vmid)
ALTER TABLE `featherpanel_vm_instances`
  ADD COLUMN IF NOT EXISTS `local_uuid` CHAR(36) NULL
  COMMENT 'LocalNode agent instance UUID' AFTER `vmid`;

-- Index for lookups
CREATE INDEX IF NOT EXISTS `idx_vm_nodes_driver` ON `featherpanel_vm_nodes` (`driver`);
CREATE INDEX IF NOT EXISTS `idx_vm_instances_local_uuid` ON `featherpanel_vm_instances` (`local_uuid`);

-- Audit log table for LocalNode actions (optional dedicated table)
CREATE TABLE IF NOT EXISTS `featherpanel_localnode_audit` (
  `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `node_id` INT UNSIGNED NOT NULL,
  `instance_uuid` CHAR(36) NULL,
  `actor_user_id` INT UNSIGNED NULL,
  `action` VARCHAR(64) NOT NULL,
  `detail` JSON NULL,
  `ip` VARCHAR(45) NULL,
  `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `idx_node_created` (`node_id`, `created_at`),
  KEY `idx_instance` (`instance_uuid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
