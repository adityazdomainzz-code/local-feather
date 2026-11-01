<?php

/*
 * Example route registration for LocalNode endpoints.
 * Include this file from your main admin router (or merge the routes).
 *
 * Requires:
 *   - LocalNodeController.php in App\Controllers\Admin
 *   - LocalNodeClient.php in App\Services
 *   - Migration applied
 */

use App\Controllers\Admin\LocalNodeController;

// Host info + capacity refresh
$router->get('/api/admin/vm-nodes/{id}/local/host', [LocalNodeController::class, 'host']);

// Instances
$router->get('/api/admin/vm-nodes/{id}/local/instances', [LocalNodeController::class, 'listInstances']);
$router->post('/api/admin/vm-nodes/{id}/local/instances', [LocalNodeController::class, 'createInstance']);

// Power actions (start|stop|restart)
$router->post('/api/admin/vm-nodes/{id}/local/instances/{uuid}/{action}', [LocalNodeController::class, 'power']);

// Delete
$router->delete('/api/admin/vm-nodes/{id}/local/instances/{uuid}', [LocalNodeController::class, 'deleteInstance']);

// Console
$router->get('/api/admin/vm-nodes/{id}/local/instances/{uuid}/console', [LocalNodeController::class, 'console']);
