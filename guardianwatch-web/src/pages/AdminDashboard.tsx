import { useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import {
  adminApi,
  ApiError,
  formatDate,
  formatMoney,
} from "../api";
import { adminAuth } from "../auth";
import type {
  AdminDevice,
  AdminProduct,
  DashboardStats,
  Order,
} from "../types";

type Tab = "stats" | "products" | "orders" | "devices";

export default function AdminDashboard() {
  const [tab, setTab] = useState<Tab>("stats");
  const [stats, setStats] = useState<DashboardStats | null>(null);
  const [products, setProducts] = useState<AdminProduct[]>([]);
  const [orders, setOrders] = useState<Order[]>([]);
  const [devices, setDevices] = useState<AdminDevice[]>([]);
  const [error, setError] = useState<string | null>(null);
  const navigate = useNavigate();

  const token = adminAuth.getToken()!;
  const user = adminAuth.getUser();

  const handle401 = (e: unknown) => {
    if (e instanceof ApiError && e.status === 401) {
      adminAuth.clear();
      navigate("/admin/login");
    } else {
      setError(e instanceof Error ? e.message : "Request failed");
    }
  };

  const loadAll = async () => {
    setError(null);
    try {
      const [s, p, o, d] = await Promise.all([
        adminApi.stats(token),
        adminApi.listProducts(token),
        adminApi.listOrders(token),
        adminApi.listDevices(token),
      ]);
      setStats(s);
      setProducts(p);
      setOrders(o);
      setDevices(d);
    } catch (e) {
      handle401(e);
    }
  };

  useEffect(() => {
    loadAll();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const logout = () => {
    adminAuth.clear();
    navigate("/admin/login");
  };

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-semibold">Admin</h1>
          <p className="text-sm text-gray-400">
            Signed in as {user?.email}
          </p>
        </div>
        <button onClick={logout} className="btn-ghost">
          Sign out
        </button>
      </div>

      <nav className="flex gap-1 border-b border-border">
        {(["stats", "products", "orders", "devices"] as Tab[]).map((t) => (
          <button
            key={t}
            onClick={() => setTab(t)}
            className={`px-4 py-2 text-sm font-medium capitalize transition-colors border-b-2 -mb-px ${
              tab === t
                ? "border-primary text-primary"
                : "border-transparent text-gray-400 hover:text-gray-200"
            }`}
          >
            {t}
          </button>
        ))}
      </nav>

      {error && (
        <div className="card border-danger/40 text-danger text-sm">
          {error}
        </div>
      )}

      {tab === "stats" && <StatsTab stats={stats} />}
      {tab === "products" && (
        <ProductsTab
          token={token}
          products={products}
          onReload={loadAll}
          onError={handle401}
        />
      )}
      {tab === "orders" && (
        <OrdersTab
          token={token}
          orders={orders}
          onReload={loadAll}
          onError={handle401}
        />
      )}
      {tab === "devices" && (
        <DevicesTab
          token={token}
          devices={devices}
          onReload={loadAll}
          onError={handle401}
        />
      )}
    </div>
  );
}

// ── Stats ────────────────────────────────────────────────────────────────

function StatsTab({ stats }: { stats: DashboardStats | null }) {
  if (!stats) return <div className="text-sm text-gray-400">Loading…</div>;

  const cards = [
    { label: "Customers", value: stats.total_customers },
    { label: "Products", value: stats.total_products },
    { label: "Devices", value: stats.total_devices },
    {
      label: "Registered devices",
      value: stats.devices_registered,
    },
    { label: "Total orders", value: stats.total_orders },
    { label: "Pending", value: stats.orders_pending },
    { label: "Paid", value: stats.orders_paid },
    { label: "Fulfilled", value: stats.orders_fulfilled },
  ];

  return (
    <div className="space-y-6">
      <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
        {cards.map((c) => (
          <div key={c.label} className="card">
            <div className="text-xs uppercase tracking-wider text-gray-400 mb-2">
              {c.label}
            </div>
            <div className="text-2xl font-semibold">{c.value}</div>
          </div>
        ))}
      </div>

      <div className="card">
        <div className="text-xs uppercase tracking-wider text-gray-400 mb-2">
          Revenue (paid + fulfilled)
        </div>
        <div className="text-3xl font-semibold">
          {formatMoney(stats.revenue_paid_cents, stats.currency)}
        </div>
      </div>
    </div>
  );
}

// ── Products ─────────────────────────────────────────────────────────────

function ProductsTab({
  token,
  products,
  onReload,
  onError,
}: {
  token: string;
  products: AdminProduct[];
  onReload: () => void;
  onError: (e: unknown) => void;
}) {
  const [creating, setCreating] = useState(false);
  const [form, setForm] = useState({
    id: "",
    name: "",
    description: "",
    price_cents: 0,
    stock_quantity: 0,
  });

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    try {
      await adminApi.createProduct(token, form);
      setCreating(false);
      setForm({ id: "", name: "", description: "", price_cents: 0, stock_quantity: 0 });
      onReload();
    } catch (e) {
      onError(e);
    }
  };

  const deactivate = async (id: string) => {
    if (!confirm(`Deactivate ${id}? It will disappear from the storefront.`))
      return;
    try {
      await adminApi.deactivateProduct(token, id);
      onReload();
    } catch (e) {
      onError(e);
    }
  };

  return (
    <div className="space-y-4">
      <div className="flex justify-end">
        <button onClick={() => setCreating((v) => !v)} className="btn-primary">
          {creating ? "Cancel" : "New product"}
        </button>
      </div>

      {creating && (
        <form onSubmit={submit} className="card space-y-4">
          <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div>
              <label className="label">Slug</label>
              <input
                value={form.id}
                onChange={(e) => setForm({ ...form, id: e.target.value })}
                className="input font-mono"
                placeholder="guardianwatch-x"
                required
              />
            </div>
            <div>
              <label className="label">Name</label>
              <input
                value={form.name}
                onChange={(e) => setForm({ ...form, name: e.target.value })}
                className="input"
                required
              />
            </div>
            <div>
              <label className="label">Price (cents)</label>
              <input
                type="number"
                value={form.price_cents}
                onChange={(e) =>
                  setForm({ ...form, price_cents: Number(e.target.value) })
                }
                className="input"
                min={0}
                required
              />
            </div>
            <div>
              <label className="label">Initial stock</label>
              <input
                type="number"
                value={form.stock_quantity}
                onChange={(e) =>
                  setForm({ ...form, stock_quantity: Number(e.target.value) })
                }
                className="input"
                min={0}
                required
              />
            </div>
          </div>
          <div>
            <label className="label">Description</label>
            <textarea
              value={form.description}
              onChange={(e) =>
                setForm({ ...form, description: e.target.value })
              }
              className="input min-h-[80px]"
              required
            />
          </div>
          <button type="submit" className="btn-primary">
            Create product
          </button>
        </form>
      )}

      <div className="card p-0 overflow-hidden">
        <table className="w-full text-sm">
          <thead className="bg-surfacehi text-gray-400 text-xs uppercase tracking-wider">
            <tr>
              <th className="text-left px-4 py-3">Slug</th>
              <th className="text-left px-4 py-3">Name</th>
              <th className="text-right px-4 py-3">Price</th>
              <th className="text-right px-4 py-3">Stock</th>
              <th className="text-center px-4 py-3">Status</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {products.map((p) => (
              <tr key={p.id} className="border-t border-border">
                <td className="px-4 py-3 font-mono text-xs">{p.id}</td>
                <td className="px-4 py-3">{p.name}</td>
                <td className="px-4 py-3 text-right">
                  {formatMoney(p.price_cents, p.currency)}
                </td>
                <td className="px-4 py-3 text-right">{p.stock_quantity}</td>
                <td className="px-4 py-3 text-center">
                  {p.active ? (
                    <span className="text-primary">active</span>
                  ) : (
                    <span className="text-gray-500">inactive</span>
                  )}
                </td>
                <td className="px-4 py-3 text-right">
                  {p.active && (
                    <button
                      onClick={() => deactivate(p.id)}
                      className="text-danger text-xs hover:underline"
                    >
                      Deactivate
                    </button>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
        {products.length === 0 && (
          <div className="p-8 text-center text-sm text-gray-400">
            No products yet.
          </div>
        )}
      </div>
    </div>
  );
}

// ── Orders ───────────────────────────────────────────────────────────────

function OrdersTab({
  token,
  orders,
  onReload,
  onError,
}: {
  token: string;
  orders: Order[];
  onReload: () => void;
  onError: (e: unknown) => void;
}) {
  const [filter, setFilter] = useState<Order["status"] | "all">("all");

  const filtered =
    filter === "all" ? orders : orders.filter((o) => o.status === filter);

  const updateStatus = async (id: string, status: Order["status"]) => {
    try {
      await adminApi.updateOrderStatus(token, id, status);
      onReload();
    } catch (e) {
      onError(e);
    }
  };

  const statuses: (Order["status"] | "all")[] = [
    "all",
    "pending",
    "paid",
    "fulfilled",
    "cancelled",
  ];

  return (
    <div className="space-y-4">
      <div className="flex gap-2">
        {statuses.map((s) => (
          <button
            key={s}
            onClick={() => setFilter(s)}
            className={`rounded-full px-3 py-1 text-xs font-medium capitalize transition-colors ${
              filter === s
                ? "bg-primary text-bg"
                : "border border-border text-gray-400 hover:text-gray-200"
            }`}
          >
            {s}
          </button>
        ))}
      </div>

      <div className="card p-0 overflow-hidden">
        <table className="w-full text-sm">
          <thead className="bg-surfacehi text-gray-400 text-xs uppercase tracking-wider">
            <tr>
              <th className="text-left px-4 py-3">Order</th>
              <th className="text-left px-4 py-3">Customer</th>
              <th className="text-right px-4 py-3">Total</th>
              <th className="text-center px-4 py-3">Status</th>
              <th className="text-right px-4 py-3">Created</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {filtered.map((o) => (
              <tr key={o.id} className="border-t border-border">
                <td className="px-4 py-3 font-mono text-xs">
                  {o.id.slice(0, 8)}
                </td>
                <td className="px-4 py-3">
                  <div>{o.customer_name}</div>
                  <div className="text-xs text-gray-500">
                    {o.customer_email}
                  </div>
                </td>
                <td className="px-4 py-3 text-right">
                  {formatMoney(o.total_cents, o.currency)}
                </td>
                <td className="px-4 py-3 text-center">
                  <span
                    className={`rounded-full px-2 py-0.5 text-xs ${
                      o.status === "paid"
                        ? "bg-primary/10 text-primary"
                        : o.status === "fulfilled"
                          ? "bg-primary/20 text-primary"
                          : o.status === "cancelled"
                            ? "bg-danger/10 text-danger"
                            : "bg-surfacehi text-gray-300"
                    }`}
                  >
                    {o.status}
                  </span>
                </td>
                <td className="px-4 py-3 text-right text-xs text-gray-500">
                  {formatDate(o.created_at)}
                </td>
                <td className="px-4 py-3 text-right">
                  <select
                    value={o.status}
                    onChange={(e) =>
                      updateStatus(o.id, e.target.value as Order["status"])
                    }
                    className="rounded border border-border bg-bg px-2 py-1 text-xs"
                  >
                    <option value="pending">pending</option>
                    <option value="paid">paid</option>
                    <option value="fulfilled">fulfilled</option>
                    <option value="cancelled">cancelled</option>
                  </select>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
        {filtered.length === 0 && (
          <div className="p-8 text-center text-sm text-gray-400">
            No {filter === "all" ? "" : filter} orders.
          </div>
        )}
      </div>
    </div>
  );
}

// ── Devices ──────────────────────────────────────────────────────────────

function DevicesTab({
  token,
  devices,
  onReload,
  onError,
}: {
  token: string;
  devices: AdminDevice[];
  onReload: () => void;
  onError: (e: unknown) => void;
}) {
  const [provisioning, setProvisioning] = useState(false);
  const [form, setForm] = useState({ product_id: "", quantity: 5 });

  const provision = async (e: React.FormEvent) => {
    e.preventDefault();
    try {
      await adminApi.provisionDevices(token, form);
      setProvisioning(false);
      onReload();
    } catch (e) {
      onError(e);
    }
  };

  const toggle = async (d: AdminDevice) => {
    try {
      if (d.status === "deactivated") {
        await adminApi.reactivateDevice(token, d.id);
      } else {
        if (!confirm(`Deactivate ${d.id}? It cannot be registered.`)) return;
        await adminApi.deactivateDevice(token, d.id);
      }
      onReload();
    } catch (e) {
      onError(e);
    }
  };

  const productIds = Array.from(
    new Set(devices.map((d) => d.product.id)),
  );

  return (
    <div className="space-y-4">
      <div className="flex justify-end">
        <button
          onClick={() => setProvisioning((v) => !v)}
          className="btn-primary"
        >
          {provisioning ? "Cancel" : "Provision devices"}
        </button>
      </div>

      {provisioning && (
        <form onSubmit={provision} className="card space-y-4">
          <div className="grid grid-cols-2 gap-4">
            <div>
              <label className="label">Product</label>
              <input
                list="product-ids"
                value={form.product_id}
                onChange={(e) =>
                  setForm({ ...form, product_id: e.target.value })
                }
                className="input font-mono"
                required
              />
              <datalist id="product-ids">
                {productIds.map((id) => (
                  <option key={id} value={id} />
                ))}
              </datalist>
            </div>
            <div>
              <label className="label">Quantity (1-500)</label>
              <input
                type="number"
                value={form.quantity}
                onChange={(e) =>
                  setForm({ ...form, quantity: Number(e.target.value) })
                }
                className="input"
                min={1}
                max={500}
                required
              />
            </div>
          </div>
          <button type="submit" className="btn-primary">
            Provision
          </button>
        </form>
      )}

      <div className="card p-0 overflow-hidden">
        <table className="w-full text-sm">
          <thead className="bg-surfacehi text-gray-400 text-xs uppercase tracking-wider">
            <tr>
              <th className="text-left px-4 py-3">ID</th>
              <th className="text-left px-4 py-3">Product</th>
              <th className="text-left px-4 py-3">Owner</th>
              <th className="text-center px-4 py-3">Status</th>
              <th className="text-right px-4 py-3">Manufactured</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {devices.map((d) => (
              <tr key={d.id} className="border-t border-border">
                <td className="px-4 py-3 font-mono text-xs">{d.id}</td>
                <td className="px-4 py-3 text-xs text-gray-400">
                  {d.product.id}
                </td>
                <td className="px-4 py-3 text-xs">
                  {d.owner_email || (
                    <span className="text-gray-500">—</span>
                  )}
                </td>
                <td className="px-4 py-3 text-center">
                  <span
                    className={`rounded-full px-2 py-0.5 text-xs ${
                      d.status === "registered"
                        ? "bg-primary/10 text-primary"
                        : d.status === "deactivated"
                          ? "bg-danger/10 text-danger"
                          : "bg-surfacehi text-gray-300"
                    }`}
                  >
                    {d.status}
                  </span>
                </td>
                <td className="px-4 py-3 text-right text-xs text-gray-500">
                  {formatDate(d.manufactured_at)}
                </td>
                <td className="px-4 py-3 text-right">
                  <button
                    onClick={() => toggle(d)}
                    className={`text-xs hover:underline ${
                      d.status === "deactivated"
                        ? "text-primary"
                        : "text-danger"
                    }`}
                  >
                    {d.status === "deactivated" ? "Reactivate" : "Deactivate"}
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
        {devices.length === 0 && (
          <div className="p-8 text-center text-sm text-gray-400">
            No devices provisioned. Run{" "}
            <code className="text-gray-200">
              python scripts/seed_shop_data.py
            </code>{" "}
            or use the button above.
          </div>
        )}
      </div>
    </div>
  );
}