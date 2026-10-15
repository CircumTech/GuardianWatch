import { useState } from "react";
import { api, formatDate } from "../api";
import type { DeviceLookup as Device } from "../types";
import { EmptyState, ErrorBanner, Spinner } from "../components/ui";

export default function DeviceLookup() {
  const [id, setId] = useState("");
  const [device, setDevice] = useState<Device | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);
    setDevice(null);
    setLoading(true);
    try {
      setDevice(await api.lookupDevice(id.trim().toUpperCase()));
    } catch (e: any) {
      setError(e.message || "Lookup failed");
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="mx-auto max-w-2xl space-y-10 fade-in">
      <div className="space-y-3">
        <h1 className="text-3xl font-semibold tracking-tight text-fg">
          Device lookup
        </h1>
        <p className="text-sm text-fg-muted">
          Enter the code printed under the strap to confirm authenticity and
          check warranty status.
        </p>
      </div>

      <form onSubmit={submit} className="flex gap-3">
        <input
          value={id}
          onChange={(e) => setId(e.target.value)}
          placeholder="GW-XXXX-XXXX"
          className="input font-mono uppercase tracking-wider"
          autoFocus
          required
          spellCheck={false}
        />
        <button
          type="submit"
          disabled={!id.trim() || loading}
          className="btn-primary shrink-0"
        >
          {loading ? (
            <>
              <Spinner size={14} /> Looking up…
            </>
          ) : (
            "Look up"
          )}
        </button>
      </form>

      {error && <ErrorBanner message={error} />}

      {device && !loading && (
        <div className="card space-y-6 fade-in">
          <div className="flex items-start justify-between gap-4">
            <div>
              <div className="text-xs font-medium uppercase tracking-wider text-fg-dim">
                Device ID
              </div>
              <div className="mt-1.5 font-mono text-xl text-fg">
                {device.id}
              </div>
            </div>
            {device.status === "registered" && (
              <span className="pill pill-primary">Registered</span>
            )}
            {device.status === "unregistered" && (
              <span className="pill pill-neutral">Unregistered</span>
            )}
            {device.status === "deactivated" && (
              <span className="pill pill-danger">Deactivated</span>
            )}
          </div>

          <dl className="grid grid-cols-2 gap-x-6 gap-y-5 border-t border-border pt-6">
            <Field label="Model" value={device.product.name} />
            <Field
              label="Firmware"
              value={device.firmware_version || "—"}
              mono
            />
            <Field
              label="Registered"
              value={formatDate(device.registered_at)}
            />
            <Field
              label="Warranty"
              value={
                device.warranty_active
                  ? `Active — ${device.warranty_months} months`
                  : "Expired or inactive"
              }
              tone={device.warranty_active ? "success" : "muted"}
            />
          </dl>
        </div>
      )}

      {!device && !error && !loading && (
        <div className="card">
          <EmptyState
            title="Enter a code to begin"
            description="Device IDs are printed under the strap — they look like GW-A1B2-C3D4."
          />
        </div>
      )}
    </div>
  );
}

function Field({
  label,
  value,
  mono,
  tone,
}: {
  label: string;
  value: string;
  mono?: boolean;
  tone?: "success" | "muted";
}) {
  const valueClass =
    tone === "success"
      ? "text-success"
      : tone === "muted"
        ? "text-fg-dim"
        : "text-fg";
  return (
    <div>
      <dt className="text-xs font-medium uppercase tracking-wider text-fg-dim">
        {label}
      </dt>
      <dd
        className={`mt-1.5 text-sm ${valueClass} ${mono ? "font-mono" : ""}`}
      >
        {value}
      </dd>
    </div>
  );
}