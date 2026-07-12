import { useState } from "react";
import Login from "./Login";
import Register from "./Register";
import Dashboard from "./Dashboard";
import Admin from "./Admin";
import { getSession, clearSession } from "./api";

export default function App() {
  const [page, setPage] = useState(getSession() ? "dashboard" : "login");

  const goToLogin = () => setPage("login");
  const goToRegister = () => setPage("register");
  const goToDashboard = () => setPage("dashboard");
  const goToAdmin = () => setPage("admin");

  const logout = () => {
    clearSession();
    goToLogin();
  };

  if (page === "admin") {
    return <Admin onBack={() => setPage(getSession() ? "dashboard" : "login")} />;
  }

  if (page === "login") {
    return <Login onOk={goToDashboard} onGoRegister={goToRegister} onGoAdmin={goToAdmin} />;
  }

  if (page === "register") {
    return <Register onGoLogin={goToLogin} />;
  }

  return <Dashboard onLogout={logout} onGoAdmin={goToAdmin} />;
}
