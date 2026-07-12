const API = ""; // same origin

export function setSession(session) {
  localStorage.setItem("session", session);
}

export function getSession() {
  return localStorage.getItem("session");
}

export function clearSession() {
  localStorage.removeItem("session");
}

async function req(path, { method = "GET", body, headers = {} } = {}) {
  const session = getSession();

  const res = await fetch(API + path, {
    method,
    headers: {
      "Content-Type": "application/json",
      ...(session ? { "X-Session": session } : {}),
      ...headers,
    },
    body: body ? JSON.stringify(body) : undefined
  });

  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.detail || "Request failed");
  return data;
}

export const api = {
  // POST /api/users — create a new user account
  register: (phone, username, password) =>
    req("/api/users", {
      method: "POST",
      body: { phone, username, password }
    }),

  // POST /api/sessions — exchange credentials for a session token
  login: (phone, password) =>
    req("/api/sessions", {
      method: "POST",
      body: { phone, password }
    }),

  // loginRaw sends the body as-is — supports { phone, password } or { username, password }
  loginRaw: (body) =>
    req("/api/sessions", { method: "POST", body }),

  // DELETE /api/sessions — invalidate the current session (logout)
  logout: () =>
    req("/api/sessions", { method: "DELETE" }),

  // GET /api/users/me — current user's profile
  me: () => req("/api/users/me"),

  // GET /api/users/me/balance — current user's balance (Redis read model)
  balance: () => req("/api/users/me/balance"),

  // GET /api/users?account_number=... or ?phone=... or ?username=... — public user lookup
  lookupAccount: (value) => {
    const isPhone = !/^\d{12}$/.test(value.trim());
    const param = isPhone
      ? `phone=${encodeURIComponent(value.trim())}`
      : `account_number=${encodeURIComponent(value.trim())}`;
    return req(`/api/users?${param}`);
  },

  // POST /api/transfers — initiate a money transfer
  transfer: (to, amount) => {
    const isPhone = !/^\d{12}$/.test(to.trim());
    const body = isPhone
      ? { phone: to.trim(), amount: Number(amount) }
      : { account_number: to.trim(), amount: Number(amount) };
    return req("/api/transfers", { method: "POST", body });
  },

  // GET /api/notifications — current user's notification list
  notifications: () => req("/api/notifications"),

  // PATCH /api/notifications/:id/ack — mark a single notification as read
  ackNotification: (id) =>
    req(`/api/notifications/${id}/ack`, { method: "PATCH" }),

  // --- Admin endpoints (require X-Admin-Secret header) ---

  // GET /api/admin/stats
  adminStats: (secret) =>
    req("/api/admin/stats", { headers: { "X-Admin-Secret": secret } }),

  // GET /api/admin/users?page=&size=&search=
  adminUsers: (secret, page = 1, size = 20, search = "") =>
    req(`/api/admin/users?page=${page}&size=${size}&search=${encodeURIComponent(search)}`, {
      headers: { "X-Admin-Secret": secret },
    }),

  // GET /api/admin/users/{id}
  adminUserDetail: (secret, userId) =>
    req(`/api/admin/users/${userId}`, {
      headers: { "X-Admin-Secret": secret },
    }),

  // GET /api/admin/transfers?page=&size=
  adminTransfers: (secret, page = 1, size = 20) =>
    req(`/api/admin/transfers?page=${page}&size=${size}`, {
      headers: { "X-Admin-Secret": secret },
    }),

  // GET /api/admin/notifications?page=&size=
  adminNotifications: (secret, page = 1, size = 20) =>
    req(`/api/admin/notifications?page=${page}&size=${size}`, {
      headers: { "X-Admin-Secret": secret },
    }),

  // Health checks (operational, no auth)
  async authServiceHealth() {
    try { return await req("/api/health/auth"); } catch (e) { return { error: e.message || "Unreachable" }; }
  },
  async accountServiceHealth() {
    try { return await req("/api/health/account"); } catch (e) { return { error: e.message || "Unreachable" }; }
  },
  async transferServiceHealth() {
    try { return await req("/api/health/transfer"); } catch (e) { return { error: e.message || "Unreachable" }; }
  },
  async notificationServiceHealth() {
    try { return await req("/api/health/notifications"); } catch (e) { return { error: e.message || "Unreachable" }; }
  },
};
