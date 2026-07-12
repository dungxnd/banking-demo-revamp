# Instana Synthetic Monitoring Scripts

API Script tests for the banking-demo application.

## Scripts

| File | Purpose | Recommended interval |
|------|---------|----------------------|
| `health-checks.js` | Ping `/health` on all 4 services | 1 min |
| `user-login-flow.js` | Login ΓåÆ balance ΓåÆ profile ΓåÆ logout | 5 min |
| `transfer-flow.js` | Full transfer + balance verification + notification check | 10 min |
| `auth-edge-cases.js` | Wrong password, missing session, invalid amount | 15 min |

## How to create a test in Instana UI

1. **Synthetic Monitoring** ΓåÆ **Create Synthetic Test**
2. Type: **API Script**
3. Paste the script content
4. Set **Variables** (click "+ Add Variable"):

   | Key | Value |
   |-----|-------|
   | `BASE_URL` | `https://npd-banking.co` |
   | `TEST_USER` | `demo1` |
   | `TEST_PASSWORD` | `demo123456` |
   | `SENDER_USER` | `demo1` |
   | `SENDER_PASSWORD` | `demo123456` |
   | `RECEIVER_USER` | `demo2` |
   | `TRANSFER_AMOUNT` | `1` |

5. Set **Location** to a PoP near your EC2 region (e.g. AWS ap-southeast-1)
6. Set **Interval** as shown in the table above
7. Under **Application**, link to your `banking-demo` Application Perspective

## Notes

- `transfer-flow.js` performs a real transfer of `TRANSFER_AMOUNT` on each run.
  Keep the amount small (default: 1). The seeded demo users need sufficient balance.
- `auth-edge-cases.js` uses hardcoded credentials for negative tests ΓÇö these are
  intentional failures that should return error codes, not successes.
- All scripts use `$synthetic.variables.*` so credentials are never hardcoded
  in the script body ΓÇö set them as Variables in the Instana UI, not here.
- `$assert` failures automatically mark the test as **FAILED** and trigger
  any Smart Alerts configured on the test.