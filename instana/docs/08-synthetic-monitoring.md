# Synthetic Monitoring — API Script Tests

> **Source:** https://www.ibm.com/docs/en/instana-observability/current?topic=instana-synthetic-monitoring
> https://www.ibm.com/docs/en/instana-observability/current?topic=tests-monitoring-endpoints-synthetic
> Condensed for: banking-demo API Script tests (Instana SaaS, Go branch)

---

## What Synthetic Monitoring Does

Synthetic monitoring simulates user interactions from remote PoP (Points of Presence) locations on a schedule, independent of real user traffic. For banking-demo it:

- **Proactively detects** when endpoints are down before users notice
- **Validates** full transaction flows (login → balance → transfer)
- **Triggers Smart Alerts** on failures or latency threshold breaches
- **Integrates with Application Perspective** for correlated tracing

> Synthetic monitoring is supported on **Instana SaaS** and Standard/Custom Edition. Not supported on Classic Edition.

---

## Test Types Used (banking-demo)

| Type | Script | Use case |
|------|--------|----------|
| API Script | `health-checks.js` | Ping `/api/health/*` on all 4 services |
| API Script | `user-login-flow.js` | Login → balance → profile → logout |
| API Script | `transfer-flow.js` | Full transfer + balance verification |
| API Script | `auth-edge-cases.js` | Negative tests (bad password, invalid amount) |

All scripts are in [`instana/synthetic/`](../synthetic/).

---

## API Routes Used by Tests (Go branch)

| Test | HTTP method | Route |
|------|------------|-------|
| Login | POST | `/api/sessions` |
| Logout | DELETE | `/api/sessions` |
| Get balance | GET | `/api/users/me/balance` |
| Get profile | GET | `/api/users/me` |
| Transfer | POST | `/api/transfers` |
| Notifications | GET | `/api/notifications` |
| Health (auth) | GET | `/api/health/auth` |
| Health (account) | GET | `/api/health/account` |
| Health (transfer) | GET | `/api/health/transfer` |
| Health (notifications) | GET | `/api/health/notifications` |

> **Note (Go branch):** Routes changed from the Python stack. The old `/api/auth/login`,
> `/api/account/me` etc. are now `/api/sessions`, `/api/users/me` etc.
> All test scripts in `instana/synthetic/` already use the new routes.

---

## Creating a Test in Instana UI

1. **Synthetic Monitoring → Synthetic tests → Create Synthetic Test**
2. Select **API** → **API Script Test**
3. Upload or paste the script content from `instana/synthetic/<script>.js`
4. Set **Variables** (click "+ Add Variable"):

| Variable | Value |
|----------|-------|
| `BASE_URL` | `https://npd-banking.co` |
| `TEST_USER` | `demo1` |
| `TEST_PASSWORD` | `demo123456` |
| `SENDER_USER` | `demo1` |
| `SENDER_PASSWORD` | `demo123456` |
| `RECEIVER_USER` | `demo2` |
| `TRANSFER_AMOUNT` | `1` |

5. Set **Location** → PoP near your EC2 region (e.g. `AWS ap-southeast-1`)
6. Set **Interval** per script:

| Script | Interval |
|--------|----------|
| `health-checks.js` | 1 min |
| `user-login-flow.js` | 5 min |
| `transfer-flow.js` | 10 min |
| `auth-edge-cases.js` | 15 min |

7. Under **Application** → link to your `banking-demo` Application Perspective

---

## Script Mechanics

Scripts use the `$synthetic` global:

```js
// Read variables set in Instana UI — never hardcode credentials
const baseUrl = $synthetic.variables.BASE_URL;
const user    = $synthetic.variables.TEST_USER;
const pass    = $synthetic.variables.TEST_PASSWORD;

// Login — POST /api/sessions (Go branch route)
const response = await $http.post(`${baseUrl}/api/sessions`, {
  json: { username: user, password: pass }
});

// Assertions — failure marks the test FAILED and triggers Smart Alerts
$assert.ok(response.status === 200, `Login failed: ${response.status}`);
```

- `$assert` failures auto-mark tests as **FAILED**
- Credentials in variables → never in script body
- Scripts have full `async/await` support

---

## Smart Alerts

Set up Smart Alerts on synthetic tests to page on:
- Test failures (any `$assert` failure)
- Response time exceeding threshold (e.g. > 2s for health checks)
- Consecutive failures (e.g. 3 of last 5 runs failed)

**Synthetic Monitoring → Create Smart Alert → select test → set conditions**

---

## Application Perspective Integration

Link synthetic tests to the `banking-demo` Application Perspective so:
- Synthetic test results appear in the AP overview
- Failed tests show correlated backend traces (if the PoP hit a traced endpoint)
- SLO dashboards include synthetic availability data

---

## Synthetic PoP Notes

- PoP = Point of Presence — Instana-managed cloud agents in AWS regions
- For **private endpoints** not reachable from the internet, deploy a **self-hosted PoP**:
  ```bash
  helm install synthetic-pop instana/synthetic-pop \
    --namespace instana-synthetic \
    --set downloadKey=<KEY> \
    --set instana.host=<BACKEND_HOST>
  ```
- banking-demo uses `https://npd-banking.co` (public) → use a managed PoP

---

## Verifying Tests

After creation the test runs on the next scheduled interval. Check results:

1. **Synthetic Monitoring → Synthetic tests** — green/red status per test
2. Click a test → **Results** tab → individual run results with response times
3. **Analytics** → search for `synthetic.test.name = health-checks` to find correlated traces
