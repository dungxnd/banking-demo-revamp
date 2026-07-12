import { useCallback, useEffect, useRef, useState, useTransition } from "react";
import Layout from "./ui/Layout";
import { api } from "./api";

const SECRET_KEY = "admin_secret";
const fmt = (n) => Number(n ?? 0).toLocaleString("vi-VN") + " ₫";

/* ── Pagination ───────────────────────────────────────────── */
function Pagination({ page, pages, total, label = "items", onChange }) {
  if (pages <= 1) return null;
  return (
    <div className="flex items-center justify-between pt-3 border-t mt-3">
      <span className="text-xs text-slate-500">
        Page {page} of {pages} · {total?.toLocaleString()} {label}
      </span>
      <div className="flex gap-2">
        <button
          disabled={page <= 1}
          onClick={() => onChange(Math.max(1, page - 1))}
          className="rounded-lg border px-3 py-1.5 text-xs font-semibold text-slate-700 hover:bg-slate-50 disabled:opacity-40"
        >← Prev</button>
        <button
          disabled={page >= pages}
          onClick={() => onChange(page + 1)}
          className="rounded-lg border px-3 py-1.5 text-xs font-semibold text-slate-700 hover:bg-slate-50 disabled:opacity-40"
        >Next →</button>
      </div>
    </div>
  );
}

/* ── Stat card ────────────────────────────────────────────── */
function StatCard({ label, value, sub, accent }) {
  const colors = {
    blue:    "from-blue-600 to-blue-700 text-white",
    emerald: "from-emerald-600 to-emerald-700 text-white",
    violet:  "from-violet-600 to-violet-700 text-white",
    amber:   "from-amber-500 to-amber-600 text-white",
    slate:   "from-slate-600 to-slate-700 text-white",
  };
  return (
    <div className={`rounded-2xl bg-gradient-to-br p-5 shadow-sm ${colors[accent] || colors.slate}`}>
      <div className="text-xs font-semibold uppercase tracking-wider opacity-75">{label}</div>
      <div className="mt-2 text-2xl font-bold">{value ?? "—"}</div>
      {sub && <div className="mt-1 text-xs opacity-70">{sub}</div>}
    </div>
  );
}

/* ── Service health badge ─────────────────────────────────── */
function HealthRow({ name, status }) {
  const ok  = status?.status === "healthy";
  const loading = status === null;
  return (
    <div className="flex items-center justify-between rounded-xl border px-4 py-3">
      <div className="flex items-center gap-3">
        <span className={`h-2.5 w-2.5 rounded-full shrink-0 ${
          loading ? "bg-slate-300 animate-pulse" : ok ? "bg-emerald-500" : "bg-red-500"
        }`} />
        <span className="text-sm font-semibold text-slate-900">{name}</span>
      </div>
      <div className="flex items-center gap-3 text-xs text-slate-500">
        {loading && <span className="italic">Checking…</span>}
        {!loading && ok && (
          <>
            <span className="rounded-full bg-emerald-50 border border-emerald-200 px-2 py-0.5 text-emerald-700 font-semibold">Healthy</span>
            <span>DB: <b className="text-slate-700">{status.database}</b></span>
            <span>Redis: <b className="text-slate-700">{status.redis}</b></span>
          </>
        )}
        {!loading && !ok && (
          <span className="rounded-full bg-red-50 border border-red-200 px-2 py-0.5 text-red-700 font-semibold">
            {status?.error || "Unhealthy"}
          </span>
        )}
      </div>
    </div>
  );
}

/* ── User detail modal ────────────────────────────────────── */
function UserDetailModal({ user, secret, onClose }) {
  const [detail, setDetail] = useState(null);
  useEffect(() => {
    api.adminUserDetail(secret, user.id).then(setDetail).catch(() => {});
  }, [user.id, secret]);

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4" onClick={onClose}>
      <div className="w-full max-w-lg rounded-2xl border bg-white shadow-xl" onClick={(e) => e.stopPropagation()}>
        {/* header */}
        <div className="flex items-center justify-between border-b px-6 py-4">
          <div>
            <h3 className="text-base font-bold text-slate-900">{detail?.username ?? `User #${user.id}`}</h3>
            <p className="text-xs text-slate-500 mt-0.5">User detail & transfer history</p>
          </div>
          <button onClick={onClose} className="rounded-lg p-1.5 text-slate-400 hover:bg-slate-100 hover:text-slate-700 text-lg leading-none">✕</button>
        </div>

        {!detail ? (
          <div className="px-6 py-12 text-center text-sm text-slate-400 animate-pulse">Loading…</div>
        ) : (
          <div className="px-6 py-5 space-y-4">
            <div className="grid grid-cols-2 gap-3">
              {[
                ["Username", detail.username],
                ["Phone",    detail.phone],
                ["Account",  detail.account_number],
              ].map(([label, val]) => (
                <div key={label} className="rounded-xl bg-slate-50 px-4 py-3">
                  <div className="text-xs text-slate-500">{label}</div>
                  <div className="mt-0.5 text-sm font-semibold text-slate-900 font-mono">{val}</div>
                </div>
              ))}
              <div className="rounded-xl bg-blue-50 px-4 py-3">
                <div className="text-xs text-blue-600">Balance</div>
                <div className="mt-0.5 text-sm font-bold text-blue-800">{fmt(detail.balance)}</div>
              </div>
            </div>
            <div className="rounded-xl bg-slate-50 px-4 py-3 text-xs text-slate-500">
              Use the Transfers tab to see this user's transaction history.
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

/* ── Admin login ──────────────────────────────────────────── */
function AdminLogin({ onAuth }) {
  const [secret, setSecret] = useState("");
  const [err, setErr]       = useState("");
  const [isPending, startTransition] = useTransition();

  const submit = (e) => {
    e.preventDefault();
    setErr("");
    startTransition(async () => {
      try {
        await api.adminStats(secret);
        localStorage.setItem(SECRET_KEY, secret);
        onAuth(secret);
      } catch {
        setErr("Invalid admin secret");
      }
    });
  };

  return (
    <div className="flex min-h-screen items-center justify-center bg-slate-50 px-4">
      <div className="w-full max-w-sm rounded-2xl border bg-white p-8 shadow-sm">
        <div className="mb-6 text-center">
          <div className="mx-auto mb-3 grid h-12 w-12 place-items-center rounded-xl bg-amber-600 text-white font-bold text-lg">A</div>
          <h1 className="text-lg font-bold text-slate-900">Admin Panel</h1>
          <p className="text-sm text-slate-500 mt-1">Enter admin secret to continue</p>
        </div>
        <form onSubmit={submit} className="space-y-3">
          <input
            type="password"
            className="w-full rounded-xl border px-4 py-3 text-sm outline-none focus:ring-2 focus:ring-amber-500"
            placeholder="Admin secret"
            value={secret}
            onChange={(e) => setSecret(e.target.value)}
            autoFocus
          />
          <button
            type="submit"
            disabled={isPending || !secret}
            className="w-full rounded-xl bg-amber-600 px-4 py-3 text-sm font-semibold text-white hover:bg-amber-700 disabled:opacity-50"
          >
            {isPending ? "Checking…" : "Enter"}
          </button>
          {err && (
            <div className="rounded-xl border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-700">{err}</div>
          )}
        </form>
      </div>
    </div>
  );
}

/* ── Main admin component ─────────────────────────────────── */
export default function Admin({ onBack }) {
  const [secret, setSecret]       = useState(localStorage.getItem(SECRET_KEY) || "");
  const [authed, setAuthed]       = useState(false);
  const [stats,  setStats]        = useState(null);

  // users
  const [users, setUsers]         = useState([]);
  const [total, setTotal]         = useState(0);
  const [pages, setPages]         = useState(0);
  const [page,  setPage]          = useState(1);
  const [searchInput, setSearchInput] = useState("");
  const [search, setSearch]       = useState("");
  const [selectedUser, setSelectedUser] = useState(null);

  // transfers
  const [transfers, setTransfers]           = useState([]);
  const [transfersTotal, setTransfersTotal] = useState(0);
  const [transfersPages, setTransfersPages] = useState(0);
  const [transfersPage, setTransfersPage]   = useState(1);

  // notifications
  const [notifications, setNotifications]               = useState([]);
  const [notificationsTotal, setNotificationsTotal]     = useState(0);
  const [notificationsPages, setNotificationsPages]     = useState(0);
  const [notificationsPage,  setNotificationsPage]      = useState(1);

  // health
  const [health, setHealth] = useState({ auth: null, account: null, transfer: null, notification: null });

  const [adminSubPage, setAdminSubPage] = useState("overview");
  const searchTimer = useRef(null);

  /* ── loaders ── */
  const loadStats = useCallback(async (s) => {
    try { setStats(await api.adminStats(s)); } catch { setStats(null); }
  }, []);

  const loadUsers = useCallback(async (s, p, q) => {
    try {
      const d = await api.adminUsers(s, p, 20, q);
      setUsers(d.users); setTotal(d.total); setPages(Math.ceil(d.total / (d.size || 20)));
    } catch { setUsers([]); }
  }, []);

  const loadTransfers = useCallback(async (s, p) => {
    try {
      const d = await api.adminTransfers(s, p, 20);
      setTransfers(d.transfers); setTransfersTotal(d.total); setTransfersPages(Math.ceil(d.total / (d.size || 20)));
    } catch { setTransfers([]); }
  }, []);

  const loadNotifications = useCallback(async (s, p) => {
    try {
      const d = await api.adminNotifications(s, p, 20);
      setNotifications(d.notifications); setNotificationsTotal(d.total); setNotificationsPages(Math.ceil(d.total / (d.size || 20)));
    } catch { setNotifications([]); }
  }, []);

  const loadHealth = useCallback(async () => {
    setHealth({ auth: null, account: null, transfer: null, notification: null });
    const [auth, account, transfer, notification] = await Promise.all([
      api.authServiceHealth(), api.accountServiceHealth(),
      api.transferServiceHealth(), api.notificationServiceHealth(),
    ]);
    setHealth({ auth, account, transfer, notification });
  }, []);

  /* ── auto-login from stored secret ── */
  useEffect(() => {
    if (!authed && secret) {
      api.adminStats(secret)
        .then((d) => { setAuthed(true); setStats(d); })
        .catch(() => { setSecret(""); localStorage.removeItem(SECRET_KEY); });
    }
  }, []);

  /* ── data reload on deps change ── */
  useEffect(() => {
    if (!authed) return;
    loadStats(secret);
    loadUsers(secret, page, search);
    loadTransfers(secret, transfersPage);
    loadNotifications(secret, notificationsPage);
    loadHealth();
  }, [authed, page, search, transfersPage, notificationsPage]);

  /* ── live search debounce ── */
  const onSearchChange = (v) => {
    setSearchInput(v);
    clearTimeout(searchTimer.current);
    searchTimer.current = setTimeout(() => { setSearch(v); setPage(1); }, 350);
  };

  const logout = () => {
    localStorage.removeItem(SECRET_KEY);
    setSecret(""); setAuthed(false);
  };

  if (!authed) return <AdminLogin onAuth={(s) => { setSecret(s); setAuthed(true); }} />;

  return (
    <Layout user="Admin" env="ADMIN" onLogout={logout} onBack={onBack}
            activePage="admin" adminSubPage={adminSubPage} onAdminSubPage={setAdminSubPage}>
      <div className="space-y-5">

        {/* ── Overview ── */}
        {adminSubPage === "overview" && (
          <>
            {/* stat cards */}
            {stats && (
              <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-5">
                <StatCard label="Total Users"     value={stats.user_count?.toLocaleString()}           accent="blue" />
                <StatCard label="Total Balance"   value={fmt(stats.total_balance)}                     accent="emerald" />
                <StatCard label="Transfers"       value={stats.transfer_count?.toLocaleString()}        accent="violet" />
                <StatCard label="Transfer Volume" value={fmt(stats.total_transfer_amount)}              accent="amber" />
                <StatCard label="Notifications"   value={stats.total_notifications?.toLocaleString()}   accent="slate" />
              </div>
            )}

            {/* users table */}
            <div className="rounded-2xl border bg-white shadow-xs">
              <div className="flex items-center justify-between border-b px-6 py-4">
                <div>
                  <div className="text-sm font-semibold text-slate-900">Users</div>
                  <div className="text-xs text-slate-500 mt-0.5">{total.toLocaleString()} registered accounts</div>
                </div>
                {/* live search */}
                <div className="flex gap-2">
                  <input
                    className="rounded-xl border px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-amber-500 w-56"
                    placeholder="Search name / phone / account…"
                    value={searchInput}
                    onChange={(e) => onSearchChange(e.target.value)}
                  />
                  {search && (
                    <button
                      onClick={() => { setSearchInput(""); setSearch(""); setPage(1); }}
                      className="rounded-xl border px-3 py-2 text-xs font-semibold text-slate-600 hover:bg-slate-50"
                    >Clear</button>
                  )}
                </div>
              </div>

              <div className="overflow-x-auto">
                <table className="w-full text-sm">
                  <thead>
                    <tr className="border-b bg-slate-50 text-left text-xs font-semibold text-slate-500 uppercase tracking-wider">
                      <th className="px-4 py-3">ID</th>
                      <th className="px-4 py-3">Username</th>
                      <th className="px-4 py-3">Phone</th>
                      <th className="px-4 py-3">Account No.</th>
                      <th className="px-4 py-3 text-right">Balance</th>
                      <th className="px-4 py-3"></th>
                    </tr>
                  </thead>
                  <tbody className="divide-y">
                    {users.map((u) => (
                      <tr key={u.id} className="hover:bg-amber-50/40 transition-colors">
                        <td className="px-4 py-3 text-slate-400 text-xs">{u.id}</td>
                        <td className="px-4 py-3 font-semibold text-slate-900">{u.username}</td>
                        <td className="px-4 py-3 text-slate-600">{u.phone}</td>
                        <td className="px-4 py-3 font-mono text-xs text-slate-500">{u.account_number}</td>
                        <td className="px-4 py-3 text-right font-semibold text-blue-700">{fmt(u.balance)}</td>
                        <td className="px-4 py-3">
                          <button
                            onClick={() => setSelectedUser(u)}
                            className="rounded-lg bg-amber-50 border border-amber-200 px-3 py-1.5 text-xs font-semibold text-amber-700 hover:bg-amber-100 transition-colors"
                          >Detail</button>
                        </td>
                      </tr>
                    ))}
                    {users.length === 0 && (
                      <tr><td colSpan={6} className="px-4 py-10 text-center text-slate-400">No users found</td></tr>
                    )}
                  </tbody>
                </table>
              </div>

              <div className="px-6 pb-4">
                <Pagination page={page} pages={pages} total={total} label="users" onChange={setPage} />
              </div>
            </div>
          </>
        )}

        {/* ── Transfers ── */}
        {adminSubPage === "transfers" && (
          <div className="rounded-2xl border bg-white shadow-xs">
            <div className="border-b px-6 py-4">
              <div className="text-sm font-semibold text-slate-900">Transfer History</div>
              <div className="text-xs text-slate-500 mt-0.5">{transfersTotal.toLocaleString()} total transfers</div>
            </div>
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b bg-slate-50 text-left text-xs font-semibold text-slate-500 uppercase tracking-wider">
                    <th className="px-4 py-3">ID</th>
                    <th className="px-4 py-3">From</th>
                    <th className="px-4 py-3">To</th>
                    <th className="px-4 py-3 text-right">Amount</th>
                    <th className="px-4 py-3">Time</th>
                  </tr>
                </thead>
                <tbody className="divide-y">
                  {transfers.map((t) => (
                    <tr key={t.id} className="hover:bg-slate-50 transition-colors">
                      <td className="px-4 py-3 text-slate-400 text-xs">{t.id}</td>
                      <td className="px-4 py-3">
                        <span className="font-semibold text-slate-900">{t.from_username}</span>
                        <span className="ml-1 text-xs text-slate-400">#{t.from_user}</span>
                      </td>
                      <td className="px-4 py-3">
                        <span className="font-semibold text-slate-900">{t.to_username}</span>
                        <span className="ml-1 text-xs text-slate-400">#{t.to_user}</span>
                      </td>
                      <td className="px-4 py-3 text-right">
                        <span className="font-semibold text-emerald-700">{fmt(t.amount)}</span>
                      </td>
                      <td className="px-4 py-3 text-xs text-slate-500">
                        {t.created_at ? new Date(t.created_at).toLocaleString() : ""}
                      </td>
                    </tr>
                  ))}
                  {transfers.length === 0 && (
                    <tr><td colSpan={5} className="px-4 py-10 text-center text-slate-400">No transfers yet</td></tr>
                  )}
                </tbody>
              </table>
            </div>
            <div className="px-6 pb-4">
              <Pagination page={transfersPage} pages={transfersPages} total={transfersTotal} label="transfers" onChange={setTransfersPage} />
            </div>
          </div>
        )}

        {/* ── Notifications ── */}
        {adminSubPage === "notifications" && (
          <div className="rounded-2xl border bg-white shadow-xs">
            <div className="border-b px-6 py-4">
              <div className="text-sm font-semibold text-slate-900">Notifications</div>
              <div className="text-xs text-slate-500 mt-0.5">{notificationsTotal.toLocaleString()} total</div>
            </div>
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b bg-slate-50 text-left text-xs font-semibold text-slate-500 uppercase tracking-wider">
                    <th className="px-4 py-3">ID</th>
                    <th className="px-4 py-3">User</th>
                    <th className="px-4 py-3">Message</th>
                    <th className="px-4 py-3">Read</th>
                    <th className="px-4 py-3">Time</th>
                  </tr>
                </thead>
                <tbody className="divide-y">
                  {notifications.map((n) => (
                    <tr key={n.id} className={`hover:bg-slate-50 transition-colors ${!n.is_read ? "bg-blue-50/30" : ""}`}>
                      <td className="px-4 py-3 text-slate-400 text-xs">{n.id}</td>
                      <td className="px-4 py-3">
                        <span className="font-semibold text-slate-900">{n.username}</span>
                        <span className="ml-1 text-xs text-slate-400">#{n.user_id}</span>
                      </td>
                      <td className="px-4 py-3 max-w-xs truncate text-slate-700">{n.message}</td>
                      <td className="px-4 py-3">
                        {n.is_read
                          ? <span className="text-xs text-slate-400">Read</span>
                          : <span className="rounded-full bg-blue-100 px-2 py-0.5 text-xs font-semibold text-blue-700">New</span>}
                      </td>
                      <td className="px-4 py-3 text-xs text-slate-500">
                        {n.created_at ? new Date(n.created_at).toLocaleString() : ""}
                      </td>
                    </tr>
                  ))}
                  {notifications.length === 0 && (
                    <tr><td colSpan={5} className="px-4 py-10 text-center text-slate-400">No notifications yet</td></tr>
                  )}
                </tbody>
              </table>
            </div>
            <div className="px-6 pb-4">
              <Pagination page={notificationsPage} pages={notificationsPages} total={notificationsTotal} label="notifications" onChange={setNotificationsPage} />
            </div>
          </div>
        )}

        {/* ── Service Health ── */}
        {adminSubPage === "health" && (
          <div className="rounded-2xl border bg-white shadow-xs">
            <div className="flex items-center justify-between border-b px-6 py-4">
              <div>
                <div className="text-sm font-semibold text-slate-900">Service Health</div>
                <div className="text-xs text-slate-500 mt-0.5">All backend microservices status</div>
              </div>
              <button
                onClick={loadHealth}
                className="rounded-xl border px-3 py-2 text-xs font-semibold text-slate-600 hover:bg-slate-50"
              >↺ Refresh</button>
            </div>
            <div className="space-y-2 p-6">
              <HealthRow name="Auth Service"         status={health.auth} />
              <HealthRow name="Account Service"      status={health.account} />
              <HealthRow name="Transfer Service"     status={health.transfer} />
              <HealthRow name="Notification Service" status={health.notification} />
            </div>
          </div>
        )}

      </div>

      {selectedUser && (
        <UserDetailModal user={selectedUser} secret={secret} onClose={() => setSelectedUser(null)} />
      )}
    </Layout>
  );
}
