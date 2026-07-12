/**
 * perf/k6/lib/helpers.js
 * Shared utilities for Go vs Python (origin/final) benchmark scenarios.
 *
 * Both stacks share the SAME top-level route structure:
 *   Kong → api-producer → queue/bus → consumers
 *
 * Route table:
 *   Action     Go (golang branch)            Python (origin/final)
 *   ─────────────────────────────────────────────────────────────────────
 *   Login      POST /api/sessions             POST /api/auth/login
 *   Register   POST /api/users                POST /api/auth/register
 *   Balance    GET  /api/users/me/balance     GET  /api/account/balance
 *   Profile    GET  /api/users/me             GET  /api/account/me
 *   Transfer   POST /api/transfers            POST /api/transfer/transfer
 *
 * Transfer body (both stacks):
 *   { username: "bob", amount: 1 }
 */

import http from 'k6/http';
import { check, sleep } from 'k6';

const STACK = __ENV.STACK_TYPE || 'go';
const BASE  = __ENV.BASE_URL   || 'http://localhost:8000';

// ── Route resolver ────────────────────────────────────────────────────────────

export const routes = {
  login:    STACK === 'go' ? '/api/sessions'          : '/api/auth/login',
  register: STACK === 'go' ? '/api/users'             : '/api/auth/register',
  balance:  STACK === 'go' ? '/api/users/me/balance'  : '/api/account/balance',
  profile:  STACK === 'go' ? '/api/users/me'          : '/api/account/me',
  transfer: STACK === 'go' ? '/api/transfers'         : '/api/transfer/transfer',
};

// ── Auth header ───────────────────────────────────────────────────────────────

export function authHeader(session) {
  return { 'X-Session': session, 'Content-Type': 'application/json' };
}

// ── Login ─────────────────────────────────────────────────────────────────────

export function login(username, password) {
  const res = http.post(`${BASE}${routes.login}`,
    JSON.stringify({ username, password }),
    { headers: { 'Content-Type': 'application/json' }, timeout: '10s' },
  );
  const ok = check(res, {
    'login 200':         (r) => r.status === 200,
    'login has session': (r) => {
      try { return !!JSON.parse(r.body).session; } catch { return false; }
    },
  });
  if (!ok || res.status !== 200) return null;
  try { return JSON.parse(res.body).session; } catch { return null; }
}

// ── Register ──────────────────────────────────────────────────────────────────

export function registerUser(username, password, phone) {
  return http.post(`${BASE}${routes.register}`,
    JSON.stringify({ username, password, phone }),
    { headers: { 'Content-Type': 'application/json' }, timeout: '10s' },
  );
}

// ── Transfer body ─────────────────────────────────────────────────────────────

export function transferBody(toUsername, amount) {
  return JSON.stringify({ username: toUsername, amount });
}

// ── Batch register + login a pool of N perf users ────────────────────────────
//
// Used by setup() to seed the user pool before VUs start.
//
// Naming convention:
//   username: `${prefix}${i}`           e.g. perf_user_0 … perf_user_19
//   phone:    `${phoneBase + i}`        e.g. 09011110000 … 09011110019
//
// Returns an array of { username, session } objects for every user that
// successfully authenticated. A 409 on register is idempotent (user exists).
//
// Retries each login up to `retries` times with `retrySleepS` second pauses.
export function batchRegisterAndLogin(n, prefix, password, phoneBase, retries = 3, retrySleepS = 2) {
  const users = [];

  for (let i = 0; i < n; i++) {
    const username = `${prefix}${i}`;
    const phone    = String(phoneBase + i);

    // Register (idempotent — 409 is fine, user already exists from a prior run).
    const reg = registerUser(username, password, phone);
    if (reg.status !== 201 && reg.status !== 200 && reg.status !== 409) {
      console.warn(`[setup] register ${username} failed: HTTP ${reg.status} — ${reg.body}`);
    }

    // Login with retry.
    let session = null;
    for (let attempt = 1; attempt <= retries; attempt++) {
      session = login(username, password);
      if (session) break;
      console.warn(`[setup] login ${username} attempt ${attempt}/${retries} failed`);
      if (attempt < retries) sleep(retrySleepS);
    }

    if (session) {
      users.push({ username, session });
    } else {
      console.error(`[setup] could not authenticate ${username} — dropping from pool`);
    }
  }

  console.log(`[setup] pool ready: ${users.length}/${n} users authenticated`);
  return users;
}
