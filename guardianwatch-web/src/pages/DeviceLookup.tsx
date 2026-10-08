import { useState } from "react";
import { api, formatDate } from "../api";
import type { DeviceLookup as Device } from "../types";

export default function DeviceLookup() {
  const [id, setId] = useState("");
  const [device, setDevice] = useState<Device | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);
    setDevice(null);
    setLoading(true);
    try {
      const d = await api.lookupDevice(id.trim().toUpperCase());
      setDevice(d);
    } catch (e: any) {
      setError(e.message || "Lookup failed");
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="space-y-8 max-w-2xl mx-auto">
      <div className="space-y-2">
        <h1 className="text-3xl font-semibold tracking-tight">
          Look up your device
        </h1>
        <p className="text-gray-400 text-sm">
          Enter the code printed under the strap to confirm it's genuine
          and check warranty status.
        </p>
      </div>

      <form onSubmit={handleSubmit} className="flex gap-3">
        <input
          value={id}
          onChange={(e) => setId(e.target.value)}
          placeholder="GW-XXXX-XXXX"
          className="input font-mono tracking-wider"
          autoFocus
          required
        />
        <button
          type="submit"
          disabled={!id.trim() || loading}
          className="btn-primary shrink-0"
        >
          {loading ? "Looking up…" : "Look up"}
        </button>
      </form>

      {error && (
        <div className="card border-danger/40 text-danger text-sm">
          {error}
        </div>
      )}

      {device && (
        <div className="card space-y-4">
          <div className="flex items-start justify-between gap-4">
            <div>
              <div className="text-xs uppercase tracking-wider text-gray-400 mb-1">
                Device
              </div>
              <div className="font-mono text-lg">{device.id}</div>
            </div>
            <div
              className={`rounded-full px-3 py-1 text-xs font-medium ${
                device.status === "registered"
                  ? "bg-primary/10 text-primary"
                  : device.status === "deactivated"
                    ? "bg-danger/10 text-danger"
                    : "bg-surfacehi text-gray-300"
              }`}
            >
              {device.status}
            </div>
          </div>

          <div className="border-t border-border pt-4 grid grid-cols-2 gap-4 text-sm">
            <div>
              <div className="text-gray-400 text-xs mb-1">Model</div>
              <div>{device.product.name}</div>
            </div>
            <div>
              <div className="text-gray-400 text-xs mb-1">Firmware</div>
              <div>{device.firmware_version || "—"}</div>
            </div>
            <div>
              <div className="text-gray-400 text-xs mb-1">Registered</div>
              <div>{formatDate(device.registered_at)}</div>
            </div>
            <div>
              <div className="text-gray-400 text-xs mb-1">Warranty</div>
              <div
                className={
                  device.warranty_active ? "text-primary" : "text-gray-500"
                }
              >
                {device.warranty_active
                  ? `Active — ${device.warranty_months} months`
                  : "Expired or inactive"}
              </div>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}