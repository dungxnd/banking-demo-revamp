const navItemClass = (active, tone = "blue") => {
  if (tone === "amber") {
    return active
      ? "rounded-xl bg-amber-50 px-3 py-2 font-semibold text-amber-700"
      : "rounded-xl px-3 py-2 font-semibold text-slate-700 transition-colors hover:bg-amber-50";
  }

  return active
    ? "rounded-xl bg-blue-50 px-3 py-2 font-semibold text-blue-700"
    : "rounded-xl px-3 py-2 font-semibold text-slate-700 transition-colors hover:bg-slate-50";
};

export default function Layout({ user, env = "LAB", onLogout, onBack, onGoAdmin, activePage = "dashboard", adminSubPage, onAdminSubPage, children }) {
  return (
    <div className="min-h-screen bg-slate-50">
      <header className="sticky top-0 z-10 border-b border-slate-200 bg-white/90 backdrop-blur">
        <div className="mx-auto flex max-w-6xl flex-col gap-4 px-4 py-3 sm:flex-row sm:items-center sm:justify-between">
          <div className="flex items-center gap-3">
            <div className="grid h-10 w-10 place-items-center rounded-xl bg-blue-600 text-sm font-bold text-white shadow-sm">
              B
            </div>
            <div>
              <div className="text-sm font-semibold text-slate-900">NPD Banking</div>
              <div className="text-xs text-slate-500">Postgres • Redis Session • WebSocket Notify</div>
            </div>
          </div>

          <div className="flex flex-wrap items-center gap-2 sm:justify-end">
            <span className={`rounded-full px-3 py-1 text-xs font-semibold ${
              env === "ADMIN" ? "bg-amber-100 text-amber-700" : "bg-slate-100 text-slate-700"
            }`}>
              {env}
            </span>
            {user && (
              <span className="rounded-full bg-slate-100 px-3 py-1 text-xs text-slate-600">
                Signed in as <span className="font-semibold text-slate-900">{user}</span>
              </span>
            )}
            {onBack && (
              <button
                onClick={onBack}
                className="rounded-xl border border-slate-200 px-3 py-2 text-xs font-semibold text-slate-700 transition-colors hover:bg-slate-50"
              >
                Back
              </button>
            )}
            <button
              onClick={onLogout}
              className="rounded-xl border border-slate-200 px-3 py-2 text-xs font-semibold text-slate-700 transition-colors hover:bg-slate-50"
            >
              Sign out
            </button>
          </div>
        </div>
      </header>

      <div className="mx-auto grid max-w-6xl grid-cols-1 gap-6 px-4 py-6 lg:grid-cols-12">
        <aside className="lg:col-span-3">
          <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm">
            <div className="text-xs font-semibold uppercase tracking-[0.18em] text-slate-500">Menu</div>
            <div className="mt-3 space-y-2 text-sm">
              <div className={navItemClass(activePage === "dashboard")}>Dashboard</div>
              {env === "ADMIN" && onAdminSubPage ? (
                <>
                  <button
                    type="button"
                    onClick={() => onAdminSubPage("overview")}
                    className={`block w-full text-left ${navItemClass(adminSubPage === "overview", "amber")}`}
                  >
                    Overview
                  </button>
                  <button
                    type="button"
                    onClick={() => onAdminSubPage("transfers")}
                    className={`block w-full text-left ${navItemClass(adminSubPage === "transfers", "amber")}`}
                  >
                    Transfers history
                  </button>
                  <button
                    type="button"
                    onClick={() => onAdminSubPage("notifications")}
                    className={`block w-full text-left ${navItemClass(adminSubPage === "notifications", "amber")}`}
                  >
                    Notifications
                  </button>
                  <button
                    type="button"
                    onClick={() => onAdminSubPage("health")}
                    className={`block w-full text-left ${navItemClass(adminSubPage === "health", "amber")}`}
                  >
                    Service health
                  </button>
                </>
              ) : (
                <>
                  <div className="rounded-xl px-3 py-2 text-slate-700">Transfers</div>
                  <div className="rounded-xl px-3 py-2 text-slate-700">Notifications</div>
                </>
              )}
              {onGoAdmin && !(env === "ADMIN" && onAdminSubPage) && (
                <button
                  type="button"
                  onClick={onGoAdmin}
                  className={`block w-full text-left ${navItemClass(activePage === "admin", "amber")}`}
                >
                  Admin panel
                </button>
              )}
              {activePage === "admin" && !onGoAdmin && (
                <div className="rounded-xl bg-amber-50 px-3 py-2 font-semibold text-amber-700">Admin panel</div>
              )}
            </div>
            <div className="mt-4 rounded-xl border border-slate-200 bg-slate-50 px-3 py-3 text-xs leading-5 text-slate-600">
              Demo focus: <span className="font-semibold">Session in Redis</span>, realtime notify via{" "}
              <span className="font-semibold">WebSocket</span>.
            </div>
          </div>
        </aside>

        <main className="lg:col-span-9">{children}</main>
      </div>
    </div>
  );
}
