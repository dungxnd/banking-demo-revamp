/**
 * Instana Synthetic Monitoring — API Script
 * Test: Login as sender → transfer → verify balance + notifications → logout
 *
 * Type:    API Script
 * Trigger: Every 10 minutes
 *
 * Variables (set in Instana UI under Synthetic test → Variables):
 *   BASE_URL        https://npd-banking.co
 *   SENDER_USER     alice
 *   SENDER_PASSWORD password123
 *   RECEIVER_USER   bob            (must exist and be different from sender)
 *   TRANSFER_AMOUNT 1              (keep small — real balance is modified)
 */

const BASE_URL = $synthetic.variables.BASE_URL        || 'https://npd-banking.co';
const SENDER   = $synthetic.variables.SENDER_USER     || 'alice';
const S_PASS   = $synthetic.variables.SENDER_PASSWORD || 'password123';
const RECEIVER = $synthetic.variables.RECEIVER_USER   || 'bob';
const AMOUNT   = Number($synthetic.variables.TRANSFER_AMOUNT) || 1;

(async () => {

  // ── Step 1: Login sender — POST /api/sessions ──────────────────────────────
  const loginRes = await $http.post(`${BASE_URL}/api/sessions`, {
    json: { username: SENDER, password: S_PASS },
    timeout: 8000,
  });
  $assert.equal(loginRes.status, 200, `Sender login failed: HTTP ${loginRes.status}`);

  const { session } = loginRes.json();
  $assert.ok(session, 'No session token returned on login');

  // ── Step 2: Get balance before — GET /api/users/me/balance ─────────────────
  const balanceBeforeRes = await $http.get(`${BASE_URL}/api/users/me/balance`, {
    headers: { 'X-Session': session },
    timeout: 5000,
  });
  $assert.equal(balanceBeforeRes.status, 200,
    `Pre-transfer balance check failed: HTTP ${balanceBeforeRes.status}`);
  const balanceBefore = balanceBeforeRes.json().balance;
  $assert.ok(balanceBefore >= AMOUNT,
    `Sender balance (${balanceBefore}) too low for transfer of ${AMOUNT}`);

  // ── Step 3: Execute transfer — POST /api/transfers ─────────────────────────
  const transferRes = await $http.post(`${BASE_URL}/api/transfers`, {
    headers: { 'X-Session': session },
    json: { username: RECEIVER, amount: AMOUNT },
    timeout: 10000,
  });
  $assert.equal(transferRes.status, 200, `Transfer failed: HTTP ${transferRes.status}`);

  const transferBody = transferRes.json();
  $assert.ok(transferBody.transfer_id, 'Transfer response missing transfer_id');
  $assert.equal(transferBody.amount, AMOUNT, 'Transfer amount mismatch');

  // ── Step 4: Verify balance decreased — GET /api/users/me/balance ───────────
  const balanceAfterRes = await $http.get(`${BASE_URL}/api/users/me/balance`, {
    headers: { 'X-Session': session },
    timeout: 5000,
  });
  $assert.equal(balanceAfterRes.status, 200,
    `Post-transfer balance check failed: HTTP ${balanceAfterRes.status}`);

  const balanceAfter = balanceAfterRes.json().balance;
  $assert.equal(balanceAfter, balanceBefore - AMOUNT,
    `Expected balance ${balanceBefore - AMOUNT}, got ${balanceAfter}`);

  // ── Step 5: Verify notification was created — GET /api/notifications ────────
  const notifRes = await $http.get(`${BASE_URL}/api/notifications`, {
    headers: { 'X-Session': session },
    timeout: 5000,
  });
  $assert.equal(notifRes.status, 200, `Notifications fetch failed: HTTP ${notifRes.status}`);

  const { notifications } = notifRes.json();
  $assert.ok(Array.isArray(notifications), 'Notifications response.notifications is not an array');
  $assert.ok(notifications.length > 0, 'No notifications found after transfer');

  const latest = notifications[0];
  $assert.ok(
    latest.message.includes(String(AMOUNT)),
    `Latest notification does not mention transfer amount ${AMOUNT}: "${latest.message}"`
  );

  // ── Step 6: Logout — DELETE /api/sessions ──────────────────────────────────
  const logoutRes = await $http.delete(`${BASE_URL}/api/sessions`, {
    headers: { 'X-Session': session },
    timeout: 5000,
  });
  $assert.equal(logoutRes.status, 204, `Logout failed: HTTP ${logoutRes.status}`);

})();
