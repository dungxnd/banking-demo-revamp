import { useState, useTransition } from "react";
import { api } from "./api";
import Card from "./ui/Card";

export default function Register({ onGoLogin }) {
  const [phone, setPhone] = useState("");
  const [username, setU] = useState("");
  const [password, setP] = useState("");
  const [msg, setMsg] = useState("");
  const [err, setErr] = useState("");
  const [isPending, startTransition] = useTransition();

  const submit = () => {
    const trimmedPhone = phone.trim();
    const trimmedUsername = username.trim();

    setErr("");
    setMsg("");

    if (!trimmedPhone) {
      setErr("Phone number is required");
      return;
    }
    if (!trimmedUsername) {
      setErr("Display name is required");
      return;
    }
    if (!password) {
      setErr("Password is required");
      return;
    }

    startTransition(async () => {
      try {
        const r = await api.register(trimmedPhone, trimmedUsername, password);
        setMsg(`Account created. Your account number: ${r.account_number}. Please sign in.`);
      } catch (e) {
        setErr(e.message || "Registration failed");
      }
    });
  };

  const onKey = (e) => {
    if (e.key === "Enter") submit();
  };

  return (
    <div className="min-h-screen bg-slate-50 px-4 py-10">
      <div className="mx-auto w-full max-w-md">
        <div className="mb-5 text-center">
          <div className="mx-auto grid h-12 w-12 place-items-center rounded-2xl bg-blue-600 text-base font-bold text-white shadow-sm">
            B
          </div>
          <h1 className="mt-4 text-2xl font-semibold text-slate-900">Create your account</h1>
          <p className="mt-1 text-sm text-slate-500">Start testing balances, transfers, and live notifications.</p>
        </div>

        <Card
          title="Registration details"
          desc="Use a phone number and display name you can easily recognize in the demo."
          footer="Security note: bcrypt has max 72 bytes password (lab constraint)."
        >
          <div className="space-y-4">
            <div>
              <label htmlFor="register-phone" className="block text-xs font-semibold text-slate-600">
                Phone number
              </label>
              <input
                id="register-phone"
                className="mt-1.5 w-full rounded-xl border border-slate-200 px-4 py-3 text-sm outline-none transition focus:border-blue-500 focus:ring-2 focus:ring-blue-500/20"
                placeholder="digits only (e.g. 0987654321)"
                inputMode="numeric"
                autoComplete="tel"
                value={phone}
                onChange={(e) => setPhone(e.target.value)}
                onKeyDown={onKey}
                disabled={isPending}
              />
            </div>

            <div>
              <label htmlFor="register-name" className="block text-xs font-semibold text-slate-600">
                Display name
              </label>
              <input
                id="register-name"
                className="mt-1.5 w-full rounded-xl border border-slate-200 px-4 py-3 text-sm outline-none transition focus:border-blue-500 focus:ring-2 focus:ring-blue-500/20"
                placeholder="e.g. Kiet Nguyen"
                autoComplete="name"
                value={username}
                onChange={(e) => setU(e.target.value)}
                onKeyDown={onKey}
                disabled={isPending}
              />
            </div>

            <div>
              <label htmlFor="register-password" className="block text-xs font-semibold text-slate-600">
                Password
              </label>
              <input
                id="register-password"
                className="mt-1.5 w-full rounded-xl border border-slate-200 px-4 py-3 text-sm outline-none transition focus:border-blue-500 focus:ring-2 focus:ring-blue-500/20"
                placeholder="min 6 chars"
                type="password"
                autoComplete="new-password"
                value={password}
                onChange={(e) => setP(e.target.value)}
                onKeyDown={onKey}
                disabled={isPending}
              />
            </div>

            <div className="rounded-xl border border-slate-200 bg-slate-50 px-4 py-3 text-xs leading-5 text-slate-600">
              After registration, you will receive an account number to use for transfers in the dashboard.
            </div>

            {msg && (
              <div className="rounded-xl border border-emerald-200 bg-emerald-50 px-4 py-3 text-sm text-emerald-800">
                {msg}
              </div>
            )}
            {err && (
              <div role="alert" className="rounded-xl border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-700">
                {err}
              </div>
            )}

            <div className="flex gap-3 pt-2">
              <button
                type="button"
                disabled={isPending}
                onClick={submit}
                className="flex-1 rounded-xl bg-blue-600 px-4 py-3 text-sm font-semibold text-white transition-colors hover:bg-blue-700 disabled:opacity-60"
              >
                {isPending ? "Creating..." : "Create account"}
              </button>
              <button
                type="button"
                onClick={onGoLogin}
                disabled={isPending}
                className="rounded-xl border border-slate-200 px-4 py-3 text-sm font-semibold text-slate-700 transition-colors hover:bg-slate-50 disabled:opacity-60"
              >
                Back to sign in
              </button>
            </div>
          </div>
        </Card>
      </div>
    </div>
  );
}
