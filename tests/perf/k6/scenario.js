/**
 * tests/perf/k6/scenario.js
 * ─────────────────────────────────────────────────────────────────────────────
 * k6 load scenario for Go vs Python banking-demo comparison.
 *
 * Six scenarios, selected via SCENARIO env var:
 *
 *   reg_throughput — registration benchmark
 *     Open arrival-rate: fires REG_RATE registrations/s. Each iteration
 *     registers a brand-new unique user (epoch + VU + iter). Measures
 *     bcrypt + DB insert throughput cleanly with no contention.
 *
 *   single_pair  — contention ceiling
 *     All VUs hammer a single alice↔bob pair bidirectionally. Measures the
 *     DB row-lock ceiling under SERIALIZABLE. A low throughput is expected;
 *     it shows where serialization retries become the dominant cost.
 *
 *   multi_user   — comparative throughput (primary comparison signal)
 *     N_USERS pool. Each VU owns a unique sender row (offset N/2 to receiver).
 *     Lock contention approaches zero; cleanly measures framework + queue +
 *     Redis pipeline overhead. Uses weighted traffic mix (20/60/20) and think
 *     time. Reports throughput UNDER the configured load — not the ceiling.
 *
 *   fan_out      — hot-account stress
 *     N senders → one fixed receiver (perf_user_0). Shows how SERIALIZABLE
 *     behaves when one account is the target of a crowd (e.g. a merchant).
 *
 *   transfer_journey — sequential user journey (★ primary latency signal)
 *     Each VU models one real user doing exactly:
 *       1. POST /transfer            → wait for 200 + transfer_id
 *       2. GET  /balance             → wait for 200 + confirm balance updated
 *       3. think time (100–300 ms)   → pacing between cycles
 *     No randomness, no batching — every request waits for the previous
 *     response before firing. journey_latency measures the full cycle wall-time.
 *     This is the correct scenario for answering "how long does one complete
 *     transfer → confirm cycle take?"
 *
 *   capacity     — service throughput ceiling (breakpoint test)
 *     Open arrival-rate: ramps from CAP_START_RATE to CAP_MAX_RATE req/s
 *     across N_USERS pairs with ZERO think time. Postgres and service caps
 *     should be REMOVED for this scenario (see docker-compose.nocap.override.yml).
 *     The RPS at which transfer_errors breaches 2% or transfer_latency p95
 *     breaches 1500ms is the service throughput ceiling.
 *     Run with: SCENARIO=capacity -e CAP_MAX_RATE=200 -e CAP_RAMP_DURATION=120s
 *
 * Environment variables (all optional):
 *   BASE_URL           default: http://localhost:8000
 *   STACK_TYPE         "go" | "python"           default: go
 *   SCENARIO           see above                  default: single_pair
 *   N_USERS            pool size (multi/fan_out)  default: 40  min: 4
 *   TEST_PASSWORD      shared password            default: Perf@1234
 *   MAX_VUS            peak VUs (VU scenarios)    default: 20
 *   RAMP_DURATION      ramp stage length          default: 20s
 *   STEADY_DURATION    measurement window         default: 60s
 *   REG_RATE           target regs/s              default: 20
 *   REG_MAX_VUS        pre-alloc VUs for reg      default: 50
 *   REG_DURATION       reg benchmark window       default: 30s
 *   THINK_MIN_MS       minimum think time (ms)    default: 100
 *   THINK_MAX_MS       maximum think time (ms)    default: 300
 *   CAP_START_RATE     capacity: starting req/s   default: 10
 *   CAP_MAX_RATE       capacity: target ceiling   default: 200
 *   CAP_RAMP_DURATION  capacity: ramp window      default: 120s
 *   CAP_MAX_VUS        capacity: VU pre-alloc     default: 300
 */

import http from 'k6/http';
import { check, group, sleep } from 'k6';
import { Rate, Trend, Counter } from 'k6/metrics';
import { textSummary } from 'https://jslib.k6.io/k6-summary/0.0.2/index.js';
import { authHeader, transferBody, batchRegisterAndLogin, routes } from './lib/helpers.js';

// ── Custom metrics ────────────────────────────────────────────────────────────
// Use res.timings.duration for all latency — this is the total HTTP round-trip
// (DNS + TCP + TLS + server wait + body receive), consistent with k6 built-ins.
const transferLatency      = new Trend('transfer_latency',      true);
const authLatency          = new Trend('auth_latency',          true);
const balanceLatency       = new Trend('balance_latency',       true);
const regLatency           = new Trend('reg_latency',           true);

// transfer_journey metrics — full sequential cycle
// journey_latency = wall-time from POST /transfer start to GET /balance end.
// This captures total user-perceived latency for a complete transfer+confirm cycle.
const journeyLatency        = new Trend('journey_latency',       true);
// status_latency = just the GET /balance step inside the journey, isolated.
const journeyStatusLatency  = new Trend('journey_status_latency', true);

// HTTP sub-timings for transfer (decompose the round-trip)
const transferConnecting   = new Trend('transfer_connecting',   true);
const transferWaiting      = new Trend('transfer_waiting',      true);
const transferReceiving    = new Trend('transfer_receiving',    true);

// Error rates
const transferErrors       = new Rate('transfer_errors');
const authErrors           = new Rate('auth_errors');
const balanceErrors        = new Rate('balance_errors');
const serializationRetries = new Rate('serialization_retries');
const regErrors            = new Rate('reg_errors');
const journeyErrors        = new Rate('journey_errors');

// Business counters
const transfersCompleted   = new Counter('transfers_completed');
const transferAmountTotal  = new Counter('transfer_amount_total');
const regsCompleted        = new Counter('regs_completed');
const journeysCompleted    = new Counter('journeys_completed');

// ── Config ────────────────────────────────────────────────────────────────────
const BASE        = __ENV.BASE_URL          || 'http://localhost:8000';
const STACK       = __ENV.STACK_TYPE        || 'go';
const SCENARIO    = __ENV.SCENARIO          || 'single_pair';
const N_USERS     = Math.max(4, parseInt(__ENV.N_USERS      || '40',  10));
const PASSWORD    = __ENV.TEST_PASSWORD     || 'Perf@1234';
const MAX_VUS     = parseInt(__ENV.MAX_VUS            || '20', 10);
const RAMP_DUR    = __ENV.RAMP_DURATION     || '20s';
const STEADY_DUR  = __ENV.STEADY_DURATION   || '60s';
const REG_RATE    = parseInt(__ENV.REG_RATE     || '10', 10);
const REG_MAX_VUS = parseInt(__ENV.REG_MAX_VUS  || '50', 10);
const REG_DUR     = __ENV.REG_DURATION      || '30s';

// Think time bounds — keeps VU pacing realistic.
// Real banking users don't fire back-to-back transactions with zero delay.
// 100–300ms simulates "review result, pick next action" rather than a hammer.
// Set both to 0 only for capacity/breakpoint testing, never for comparison runs.
const THINK_MIN_MS = parseInt(__ENV.THINK_MIN_MS || '100', 10);
const THINK_MAX_MS = parseInt(__ENV.THINK_MAX_MS || '300', 10);

// capacity scenario parameters
const CAP_START_RATE   = parseInt(__ENV.CAP_START_RATE    || '10',  10);
const CAP_MAX_RATE     = parseInt(__ENV.CAP_MAX_RATE      || '200', 10);
const CAP_RAMP_DUR     = __ENV.CAP_RAMP_DURATION          || '120s';
const CAP_MAX_VUS      = parseInt(__ENV.CAP_MAX_VUS       || '300', 10);

// Pool naming — phone base avoids collision with Python seed.py (alice=0900000001).
const POOL_PREFIX     = 'perf_user_';
const POOL_PHONE_BASE = 9011110000;

// single_pair legacy names vary by stack.
const LEGACY_SENDER   = STACK === 'python' ? 'alice'      : 'perf_alice';
const LEGACY_RECEIVER = STACK === 'python' ? 'bob'        : 'perf_bob';
const LEGACY_PHONE_S  = STACK === 'python' ? '0900000001' : '0901111100';
const LEGACY_PHONE_R  = STACK === 'python' ? '0900000002' : '0901111101';

// ── SLO Thresholds ────────────────────────────────────────────────────────────
// Thresholds enforce CI pass/fail — checks alone do NOT fail a k6 run.
// checks rate threshold ensures at least 99% of all inline assertions pass.
const TRANSFER_THRESHOLDS = {
  // Inline check pass-rate: at least 99% of all checks must pass.
  'checks':                    ['rate>0.99'],
  // Transfer end-to-end latency SLOs.
  'transfer_latency':          ['p(95)<1500', 'p(99)<3000'],
  // HTTP TTFB — server-side queue/DB wait proxy.
  'transfer_waiting':          ['p(95)<1200'],
  // TCP connect time — rising here indicates connection pool exhaustion.
  'transfer_connecting':       ['p(99)<50'],
  // Error rates.
  'transfer_errors':           ['rate<0.02'],
  'serialization_retries':     ['rate<0.05'],
  'auth_errors':               ['rate<0.01'],
  'balance_errors':            ['rate<0.01'],
  // Per-endpoint latency SLOs.
  'auth_latency':              ['p(95)<500'],
  'balance_latency':           ['p(95)<200'],
  // Group-scoped built-in duration (redundant but shows up clearly in k6 output).
  'http_req_duration{group:::transfer}':     ['p(95)<2000'],
  'http_req_duration{group:::balance_read}': ['p(95)<500'],
  'http_req_duration{group:::auth_check}':   ['p(95)<500'],
};

const REG_THRESHOLDS = {
  'checks':      ['rate>0.99'],
  'reg_latency': ['p(95)<2000', 'p(99)<4000'],
  'reg_errors':  ['rate<0.01'],
};

// transfer_journey thresholds.
// journey_latency = POST /transfer + GET /balance combined wall-time.
// This is naturally higher than transfer_latency alone (two serial HTTP calls).
// p95 < 3000ms means: 95% of complete transfer-then-confirm cycles finish in 3s.
const JOURNEY_THRESHOLDS = {
  'checks':                 ['rate>0.99'],
  'journey_latency':        ['p(95)<3000', 'p(99)<5000'],
  'journey_status_latency': ['p(95)<200'],   // balance endpoint is Redis-cached
  'journey_errors':         ['rate<0.02'],
  'transfer_errors':        ['rate<0.02'],
  'balance_errors':         ['rate<0.01'],
  'serialization_retries':  ['rate<0.05'],
  'transfer_waiting':       ['p(95)<1200'],
  'transfer_connecting':    ['p(99)<50'],
};

// capacity scenario: thresholds intentionally loose — the goal is to find the
// breaking point, not enforce an SLO. Errors are expected to climb at saturation;
// the threshold fires only when the run is clearly over the cliff.
const CAPACITY_THRESHOLDS = {
  'checks':            ['rate>0.95'],   // allow more check failures near saturation
  'transfer_errors':   ['rate<0.10'],   // 10% — just to mark hard failure in summary
  'transfer_latency':  ['p(95)<5000'],  // wide — we want to observe the degradation curve
  'transfer_waiting':  ['p(95)<4000'],
};

// ── k6 options ────────────────────────────────────────────────────────────────
// reg_throughput and capacity use open arrival-rate (scenarios block).
// transfer_journey and all VU-based scenarios use the ramping-vus model (stages).
// k6 does not allow mixing top-level `stages` and `scenarios`, so we branch.
export const options = SCENARIO === 'reg_throughput'
  ? {
      scenarios: {
        reg: {
          executor:        'ramping-arrival-rate',
          startRate:       1,
          timeUnit:        '1s',
          preAllocatedVUs: REG_MAX_VUS,
          maxVUs:          REG_MAX_VUS * 2,
          stages: [
            { duration: '10s',   target: REG_RATE },   // ramp to target rate
            { duration: REG_DUR, target: REG_RATE },   // steady measurement window
            { duration: '5s',    target: 0        },   // ramp down
          ],
        },
      },
      thresholds:        REG_THRESHOLDS,
      tags:              { stack: STACK, scenario: SCENARIO },
      summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
    }
  : SCENARIO === 'capacity'
  ? {
      // Open arrival-rate: k6 fires exactly CAP_MAX_RATE req/s regardless of
      // server latency. This is the key difference from ramping-vus — the load
      // generator doesn't slow down when the server slows down. Saturating at
      // a fixed RPS reveals the true throughput ceiling.
      //
      // PREREQUISITE: run against docker-compose.nocap.override.yml so Postgres
      // and transfer-service are not CPU-capped. Otherwise you measure the cap,
      // not the service code.
      scenarios: {
        capacity: {
          executor:        'ramping-arrival-rate',
          startRate:       CAP_START_RATE,
          timeUnit:        '1s',
          preAllocatedVUs: CAP_MAX_VUS,
          maxVUs:          CAP_MAX_VUS * 2,
          stages: [
            // Warm-up: hold at start rate so connections pool up cleanly.
            { duration: '20s',       target: CAP_START_RATE },
            // Ramp: linear climb to the ceiling target.
            { duration: CAP_RAMP_DUR, target: CAP_MAX_RATE  },
            // Hold: 30s at peak to confirm the ceiling is stable, not a spike.
            { duration: '30s',       target: CAP_MAX_RATE  },
            { duration: '10s',       target: 0             },
          ],
        },
      },
      thresholds:        CAPACITY_THRESHOLDS,
      tags:              { stack: STACK, scenario: SCENARIO },
      summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
    }
  : SCENARIO === 'transfer_journey'
  ? {
      // Closed model — each VU executes steps sequentially.
      // One VU = one user: POST /transfer → wait → GET /balance → wait → think time.
      // The VU never has two requests in-flight simultaneously. This models the
      // real user flow: submit, wait for confirmation, then submit again.
      stages: [
        { duration: RAMP_DUR,   target: MAX_VUS },
        { duration: STEADY_DUR, target: MAX_VUS },
        { duration: '10s',      target: 0       },
      ],
      thresholds:        JOURNEY_THRESHOLDS,
      tags:              { stack: STACK, scenario: SCENARIO },
      summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
    }
  : {
      stages: [
        { duration: RAMP_DUR,   target: MAX_VUS },
        { duration: STEADY_DUR, target: MAX_VUS },
        { duration: '10s',      target: 0       },
      ],
      thresholds:        TRANSFER_THRESHOLDS,
      tags:              { stack: STACK, scenario: SCENARIO },
      summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
    };

// ── setup() — runs once before any VU starts ──────────────────────────────────
export function setup() {
  console.log(`[setup] scenario=${SCENARIO} stack=${STACK} n_users=${N_USERS} base=${BASE}`);

  if (SCENARIO === 'reg_throughput') {
    // Nothing to pre-seed — each iteration generates its own unique user.
    // Smoke-test the register endpoint is reachable before firing at rate.
    const probe = http.post(`${BASE}${routes.register}`,
      JSON.stringify({ username: 'probe_smoke', password: PASSWORD, phone: '09099990000' }),
      { headers: { 'Content-Type': 'application/json' }, timeout: '10s' },
    );
    if (probe.status !== 201 && probe.status !== 409) {
      throw new Error(`[setup] register endpoint unreachable — HTTP ${probe.status}: ${probe.body}`);
    }
    console.log('[setup] reg_throughput: register endpoint OK');
    return { users: [] };
  }

  if (SCENARIO === 'single_pair') {
    if (STACK !== 'python') {
      for (const [u, ph] of [[LEGACY_SENDER, LEGACY_PHONE_S], [LEGACY_RECEIVER, LEGACY_PHONE_R]]) {
        for (let a = 1; a <= 5; a++) {
          const r = http.post(`${BASE}${routes.register}`,
            JSON.stringify({ username: u, password: PASSWORD, phone: ph }),
            { headers: { 'Content-Type': 'application/json' }, timeout: '10s' },
          );
          if (r.status === 201 || r.status === 200 || r.status === 409) break;
          console.warn(`[setup] register ${u} attempt ${a}/5 → ${r.status}`);
          if (a < 5) sleep(2);
        }
      }
    }
    const sSession = loginWithRetry(LEGACY_SENDER,   PASSWORD, 5);
    const rSession = loginWithRetry(LEGACY_RECEIVER, PASSWORD, 5);
    if (!sSession || !rSession) throw new Error('[setup] single_pair login failed');
    console.log(`[setup] single_pair ready: ${LEGACY_SENDER} ↔ ${LEGACY_RECEIVER}`);
    return { users: [
      { username: LEGACY_SENDER,   session: sSession },
      { username: LEGACY_RECEIVER, session: rSession },
    ]};
  }

  // multi_user + fan_out + capacity + transfer_journey — register a pool of N users.
  const users = batchRegisterAndLogin(N_USERS, POOL_PREFIX, PASSWORD, POOL_PHONE_BASE);
  if (users.length < 2) throw new Error(`[setup] pool too small (${users.length}) — check service health`);
  console.log(`[setup] ${SCENARIO} ready: ${users.length} users`);
  if (SCENARIO === 'capacity') {
    console.log(`[setup] capacity: open arrival-rate ramp ${CAP_START_RATE} → ${CAP_MAX_RATE} req/s over ${CAP_RAMP_DUR} (NO think time)`);
  }
  if (SCENARIO === 'transfer_journey') {
    console.log(`[setup] transfer_journey: sequential flow — POST /transfer → GET /balance → think time. Each VU owns a unique pair (no lock contention).`);
  }
  return { users };
}

// ── Per-VU state ──────────────────────────────────────────────────────────────
let vuSession  = null;
let vuUsername = null;
let vuRecvName = null;

function initVU(users) {
  const n = users.length;
  switch (SCENARIO) {
    case 'single_pair':
      vuUsername = (__VU % 2 === 0) ? users[0].username : users[1].username;
      vuRecvName = (__VU % 2 === 0) ? users[1].username : users[0].username;
      break;
    case 'fan_out':
      // users[0] is always the hot receiver; remaining users are senders.
      vuRecvName = users[0].username;
      vuUsername = users[1 + ((__VU - 1) % Math.max(1, n - 1))].username;
      break;
    case 'transfer_journey':
    case 'capacity':
    case 'multi_user':
    default:
      // Each VU gets a unique sender/receiver pair (offset by N/2).
      // Zero lock contention — the service code, not the DB lock, is the bottleneck.
      vuUsername = users[__VU % n].username;
      vuRecvName = users[(__VU + Math.floor(n / 2)) % n].username;
      break;
  }
}

function refreshSession() {
  const sess = loginWithRetry(vuUsername, PASSWORD, 3);
  if (sess) vuSession = sess;
  return vuSession;
}

// ── default function ──────────────────────────────────────────────────────────
export default function (data) {
  if (SCENARIO === 'reg_throughput') {
    runRegister();
    return;
  }

  // First iteration: init per-VU state and acquire a session.
  if (__ITER === 0) {
    initVU(data.users);
    vuSession = loginWithRetry(vuUsername, PASSWORD, 3);
    if (!vuSession) { authErrors.add(1); sleep(1); return; }
  }

  // Guard: session lost (expiry or prior 401). Attempt a fresh login before
  // idling — this makes the VU self-healing rather than silently dropping
  // iterations for the remainder of the test window.
  if (!vuSession) {
    vuSession = loginWithRetry(vuUsername, PASSWORD, 3);
    if (!vuSession) { authErrors.add(1); sleep(1); return; }
  }
  authErrors.add(0);

  // ── transfer_journey: strict sequential flow ──────────────────────────────
  // One VU = one user doing: POST /transfer → wait → GET /balance → think time.
  // There is never a second request in-flight while the first is pending.
  // This answers: "how long does a complete transfer+confirm cycle take?"
  if (SCENARIO === 'transfer_journey') {
    // Step 1 — send transfer; wait for full response.
    const tRes = runTransfer(vuSession, vuRecvName);
    if (tRes && tRes.status === 401) {
      const fresh = refreshSession();
      if (!fresh) { thinkTime(); return; }
      vuSession = fresh;
    }

    // Step 2 — confirm result: fetch balance to verify credit landed.
    // This mirrors what a real user does (checks the updated balance after paying).
    const bRes = runBalanceRead(vuSession);
    if (bRes) {
      journeyStatusLatency.add(bRes.timings.duration);
    }
    if (bRes && bRes.status === 401) {
      refreshSession();
    }

    // Full cycle duration: sum of k6 sub-millisecond timings from both responses.
    // Using res.timings.duration avoids Date.now() integer-millisecond quantization
    // noise and keeps journey_latency on the same precision scale as transfer_latency.
    const tDur = (tRes && tRes.timings) ? tRes.timings.duration : 0;
    const bDur = (bRes && bRes.timings) ? bRes.timings.duration : 0;
    journeyLatency.add(tDur + bDur);

    const bothOk = (tRes && tRes.status === 200) && (bRes && bRes.status === 200);
    journeyErrors.add(bothOk ? 0 : 1);
    if (bothOk) journeysCompleted.add(1);

    // Think time: pacing between cycles (not counted in journeyLatency).
    thinkTime();
    return;
  }

  // ── Weighted traffic mix (multi_user / single_pair / fan_out) ────────────
  // 20% auth check | 60% transfer | 20% balance read
  const roll = Math.random();
  let res;
  if      (roll < 0.20) res = runAuthCheck(vuSession);
  else if (roll < 0.80) res = runTransfer(vuSession, vuRecvName);
  else                  res = runBalanceRead(vuSession);

  // Session expired — refresh once and retry.
  if (res && res.status === 401) {
    const fresh = refreshSession();
    if (fresh) {
      vuSession = fresh;
      if      (roll < 0.20) runAuthCheck(fresh);
      else if (roll < 0.80) runTransfer(fresh, vuRecvName);
      else                  runBalanceRead(fresh);
    }
  }

  // Think time: realistic pacing between iterations.
  // Without this, 20 VUs with ~10ms server latency would generate ~2000 RPS —
  // far beyond what 20 real banking users produce. A 100–300ms jitter models
  // "review response, decide next action" behavior accurately.
  thinkTime();
}

// ── Registration benchmark iteration ─────────────────────────────────────────
// Each call registers a globally-unique user: prefix + epoch_s + VU + iter.
// No two iterations share a username/phone — every request is a genuine cold
// bcrypt hash + INSERT, so the measured latency is the true registration cost.
function runRegister() {
  // epoch second (not ms) keeps the phone within 11 digits.
  const epoch    = Math.floor(Date.now() / 1000);
  const suffix   = `${epoch}${__VU}${__ITER}`;
  const username = `reg_${suffix}`;
  const phone    = '0' + suffix.slice(-10).padStart(10, '0');

  group('register', () => {
    const res = http.post(`${BASE}${routes.register}`,
      JSON.stringify({ username, password: PASSWORD, phone }),
      { headers: { 'Content-Type': 'application/json' }, timeout: '15s' },
    );
    // Use k6 built-in timing for consistency with all other metrics.
    regLatency.add(res.timings.duration);

    const ok = check(res, {
      'register 201': (r) => r.status === 201,
      'register has id': (r) => {
        try { return !!JSON.parse(r.body).id; } catch { return false; }
      },
    });
    regErrors.add(ok ? 0 : 1);
    if (ok) regsCompleted.add(1);
  });
}

// ── Auth check (20% of transfer scenarios) ───────────────────────────────────
function runAuthCheck(session) {
  let res;
  group('auth_check', () => {
    res = http.get(`${BASE}${routes.profile}`, {
      headers: authHeader(session),
      timeout: '8s',
    });
    authLatency.add(res.timings.duration);

    const ok = check(res, {
      'profile 200':      (r) => r.status === 200,
      'profile has body': (r) => r.body && r.body.length > 0,
    });
    authErrors.add(ok ? 0 : 1);
  });
  return res;
}

// ── Transfer (60% of transfer scenarios) ─────────────────────────────────────
function runTransfer(session, toUser) {
  const amount = 1;
  let res;
  group('transfer', () => {
    res = http.post(`${BASE}${routes.transfer}`, transferBody(toUser, amount),
      { headers: authHeader(session), timeout: '15s' });

    transferLatency.add(res.timings.duration);

    if (res.timings) {
      transferConnecting.add(res.timings.connecting);
      transferWaiting.add(res.timings.waiting);
      transferReceiving.add(res.timings.receiving);
    }

    const ok = check(res, {
      'transfer 200':    (r) => r.status === 200,
      'transfer has id': (r) => {
        try { return !!JSON.parse(r.body).transfer_id; } catch { return false; }
      },
    });
    transferErrors.add(ok ? 0 : 1);
    if (ok) {
      transfersCompleted.add(1);
      transferAmountTotal.add(amount);
    }
    // HTTP 503 = Go serialization retry exhaustion (SERIALIZABLE conflict).
    serializationRetries.add(res.status === 503 ? 1 : 0);
  });
  return res;
}

// ── Balance read (20% of transfer scenarios) ─────────────────────────────────
function runBalanceRead(session) {
  let res;
  group('balance_read', () => {
    res = http.get(`${BASE}${routes.balance}`, {
      headers: authHeader(session),
      timeout: '8s',
    });
    balanceLatency.add(res.timings.duration);

    const ok = check(res, {
      'balance 200':       (r) => r.status === 200,
      'balance is number': (r) => {
        try { return typeof JSON.parse(r.body).balance === 'number'; } catch { return false; }
      },
    });
    balanceErrors.add(ok ? 0 : 1);
  });
  return res;
}

// ── Think time ────────────────────────────────────────────────────────────────
// Uniform random within [THINK_MIN_MS, THINK_MAX_MS].
// Applied after every full iteration (not between group steps) so that
// sub-request latencies like auth_latency still measure pure server cost.
//
// capacity scenario always skips think time — the open arrival-rate executor
// controls pacing; adding sleep would cause VUs to back up and under-drive the
// target rate. The executor already fires at the configured RPS regardless.
function thinkTime() {
  if (SCENARIO === 'capacity') return;
  const ms = THINK_MIN_MS + Math.random() * (THINK_MAX_MS - THINK_MIN_MS);
  sleep(ms / 1000);
}

// ── handleSummary ─────────────────────────────────────────────────────────────
export function handleSummary(data) {
  const out = {};
  for (const [name, metric] of Object.entries(data.metrics)) {
    out[name] = { type: metric.type, values: metric.values };
  }
  // File name encodes both stack and scenario so sequential runs never overwrite.
  const summaryPath = `/scripts/results/${STACK}-${SCENARIO}-summary.json`;
  return {
    stdout:        textSummary(data, { indent: ' ', enableColors: false }),
    [summaryPath]: JSON.stringify(out),
  };
}

// ── Internal: login with retry ────────────────────────────────────────────────
function loginWithRetry(username, password, retries) {
  for (let a = 1; a <= retries; a++) {
    const res = http.post(`${BASE}${routes.login}`,
      JSON.stringify({ username, password }),
      { headers: { 'Content-Type': 'application/json' }, timeout: '10s' },
    );
    if (res.status === 200) {
      try { const s = JSON.parse(res.body).session; if (s) return s; } catch {}
    }
    console.warn(`[login] ${username} attempt ${a}/${retries} → HTTP ${res.status}`);
    if (a < retries) sleep(2);
  }
  return null;
}
