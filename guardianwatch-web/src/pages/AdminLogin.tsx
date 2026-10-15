import { useState } from "react";
import { useNavigate } from "react-router-dom";
import { adminApi } from "../api";
import { adminAuth } from "../auth";
import { ErrorBanner, Spinner } from "../components/ui";

export default function AdminLogin() {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [attempts, setAttempts] = useState(0);
  const [lockUntil, setLockUntil] = useState(0);
  const navigate = useNavigate();

  const locked = Date.now() < lockUntil;
  const remaining = Math.max(0, Math.ceil((lockUntil - Date.now()) / 1000));

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (locked) return;
    setError(null);
    setLoading(true);
    try {
      const res = await adminApi.login(email.trim().toLowerCase(), password);
      adminAuth.set(res.access_token, res.admin);
      navigate("/admin");
    } catch (e: any) {
      const next = attempts + 1;
      if (next >= 5) {
        setLockUntil(Date.now() + 60_000);
        setAttempts(0);
      } else {
        setAttempts(next);
      }
      setError(e.message || "Login failed");
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="mx-auto mt-16 max-w-sm fade-in">
      <div className="card p-8">
        <div className="mb-8 space-y-1.5">
          <h1 className="text-xl font-semibold tracking-tight text-fg">
            Admin sign-in
          </h1>
          <p className="text-sm text-fg-muted">
            Restricted area. Accounts are provisioned from the server.
          </p>
        </div>

        <form onSubmit={submit} className="space-y-5">
          <div>
            <label className="label" htmlFor="admin-email">
              Email
            </label>
            <input
              id="admin-email"
              type="email"
              autoComplete="username"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              className="input"
              autoFocus
              required
            />
          </div>

          <div>
            <label className="label" htmlFor="admin-password">
              Password
            </label>
            <input
              id="admin-password"
              type="password"
              autoComplete="current-password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              className="input"
              required
            />
          </div>

          {error && <ErrorBanner message={error} />}

          <button
            type="submit"
            disabled={loading || locked}
            className="btn-primary w-full py-2.5"
          >
            {locked ? (
              `Locked — retry in ${remaining}s`
            ) : loading ? (
              <>
                <Spinner size={14} /> Signing in…
              </>
            ) : (
              "Sign in"
            )}
          </button>
        </form>
      </div>

      <p className="mt-6 text-center text-xs text-fg-dim">
        Sessions expire after 12 hours.
      </p>
    </div>
  );
}