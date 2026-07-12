/**
 * Instana Synthetic Monitoring — API Script
 * Test: Health checks for all four banking services
 *
 * Type:    API Script
 * Trigger: Every 1 minute
 *
 * Variables (set in Instana UI under Synthetic test → Variables):
 *   BASE_URL   https://npd-banking.co
 */

const BASE_URL = $synthetic.variables.BASE_URL || 'https://npd-banking.co';

const services = [
  { name: 'auth-service',         path: '/api/health/auth' },
  { name: 'account-service',      path: '/api/health/account' },
  { name: 'transfer-service',     path: '/api/health/transfer' },
  { name: 'notification-service', path: '/api/health/notifications' },
];

(async () => {

  for (const svc of services) {
    const res = await $http.get(`${BASE_URL}${svc.path}`, {
      timeout: 5000,
    });
    $assert.equal(res.status, 200,
      `${svc.name} health check returned ${res.status}, expected 200`);

    const body = res.json();
    $assert.equal(body.status, 'healthy',
      `${svc.name} reported status="${body.status}", expected "healthy"`);
  }

})();
