import { useState, useTransition } from "react";
import { api, setSession } from "./api";

export default function Login({ onOk, onGoRegister, onGoAdmin }) {
  const [identifier, setIdentifier] = useState(""); // phone or username
  const [password, setP] = useState("");
  const [showPw, setShowPw] = useState(false);
  const [err, setErr] = useState("");
  const [isPending, startTransition] = useTransition();

  const submit = () => {
    setErr("");
    const id = identifier.trim();
    if (!id)       { setErr("Phone number or username is required"); return; }
    if (!password) { setErr("Password is required"); return; }
    // Determine whether the value looks like a phone (digits only) or a username
    const isPhone = /^\d+$/.test(id);
    startTransition(async () => {
      try {
        const body = isPhone ? { phone: id, password } : { username: id, password };
        const r = await api.loginRaw(body);
        setSession(r.session);
        onOk();
      } catch (e) {
        setErr(e.message || "Login failed");
      }
    });
  };

  const onKey = (e) => { if (e.key === "Enter") submit(); };

  return (
    <div className="min-h-screen bg-slate-50 flex items-center justify-center px-4 py-10">
      <div className="w-full max-w-md">
        <div className="mb-5 text-center">
          <div className="inline-flex items-center gap-2 rounded-full border border-slate-200 bg-white px-3 py-1 text-xs font-medium text-slate-500">
            Demo banking workspace
          </div>
        </div>

        <div className="overflow-hidden rounded-2xl border border-slate-200 bg-white shadow-sm">
          <div className="bg-gradient-to-r from-blue-600 to-blue-700 px-7 py-5 flex items-center gap-3">
            <div className="grid h-10 w-10 shrink-0 place-items-center rounded-xl bg-white/20 text-lg font-bold text-white">
              B
            </div>
            <div>
              <div className="text-base font-semibold leading-tight text-white">NPD Banking</div>
              <div className="mt-0.5 text-xs text-blue-100">Postgres · Redis Session · WebSocket · Username Login</div>
            </div>
          </div>

          <div className="px-7 py-6">
            <h1 className="text-2xl font-semibold text-slate-900">Welcome back</h1>
            <p className="mt-1 mb-6 text-sm text-slate-500">
              Sign in to access your account balance, transfers, and live notifications.
            </p>

            <div className="mb-5 grid grid-cols-2 gap-3 rounded-2xl border border-slate-200 bg-slate-50 p-3 text-xs text-slate-600">
              <div>
                <div className="font-semibold text-slate-900">Realtime updates</div>
                <div className="mt-1">WebSocket-powered notifications in the dashboard.</div>
              </div>
              <div>
                <div className="font-semibold text-slate-900">Flexible sign-in</div>
                <div className="mt-1">Use phone number or username — both are accepted.</div>
              </div>
            </div>

            <div className="space-y-4">
              <div>
                <label htmlFor="login-identifier" className="mb-1.5 block text-xs font-semibold text-slate-600">
                  Phone number or username
                </label>
                <input
                  id="login-identifier"
                  className="w-full rounded-xl border border-slate-200 px-4 py-3 text-sm outline-none transition focus:border-blue-500 focus:ring-2 focus:ring-blue-500/20"
                  placeholder="e.g. 0987654321 or johndoe"
                  autoComplete="username"
                  value={identifier}
                  onChange={(e) => setIdentifier(e.target.value)}
                  onKeyDown={onKey}
                  disabled={isPending}
                />
              </div>

              <div>
                <div className="mb-1.5 flex items-center justify-between gap-3">
                  <label htmlFor="login-pw" className="block text-xs font-semibold text-slate-600">
                    Password
                  </label>
                  <span className="text-[11px] text-slate-400">Press Enter to sign in</span>
                </div>
                <div className="relative">
                  <input
                    id="login-pw"
                    className="w-full rounded-xl border border-slate-200 px-4 py-3 pr-12 text-sm outline-none transition focus:border-blue-500 focus:ring-2 focus:ring-blue-500/20"
                    placeholder="Your password"
                    type={showPw ? "text" : "password"}
                    autoComplete="current-password"
                    value={password}
                    onChange={(e) => setP(e.target.value)}
                    onKeyDown={onKey}
                    disabled={isPending}
                  />
                  <button
                    type="button"
                    tabIndex={-1}
                    onClick={() => setShowPw((v) => !v)}
                    className="absolute right-3 top-1/2 -translate-y-1/2 text-xs font-semibold text-slate-400 hover:text-slate-600"
                    aria-label={showPw ? "Hide password" : "Show password"}
                  >
                    {showPw ? "Hide" : "Show"}
                  </button>
                </div>
              </div>
            </div>

            {err && (
              <div role="alert" className="mt-4 rounded-xl border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-700">
                {err}
              </div>
            )}

            <div className="mt-5 flex gap-3">
              <button
                onClick={submit}
                disabled={isPending}
                className="flex-1 rounded-xl bg-blue-600 px-4 py-3 text-sm font-semibold text-white transition-colors hover:bg-blue-700 active:bg-blue-800 disabled:opacity-60"
              >
                {isPending ? "Signing in…" : "Sign in"}
              </button>
              <button
                onClick={onGoRegister}
                disabled={isPending}
                className="flex-1 rounded-xl border border-slate-200 px-4 py-3 text-sm font-semibold text-slate-700 transition-colors hover:bg-slate-50 disabled:opacity-60"
              >
                Create account
              </button>
            </div>
          </div>

          <div className="flex items-center justify-between border-t border-slate-200 bg-slate-50 px-7 py-3 text-xs text-slate-400">
            <span>© Banking Demo Lab · Postgres + Redis</span>
            {onGoAdmin && (
              <button
                onClick={onGoAdmin}
                className="font-semibold text-amber-600 transition-colors hover:text-amber-700"
              >
                Admin →
              </button>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
