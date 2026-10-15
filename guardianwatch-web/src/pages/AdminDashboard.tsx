import { useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import { adminApi, ApiError, formatDate, formatMoney } from "../api";
import { adminAuth } from "../auth";
import type { AdminDevice, AdminProduct, DashboardStats, Order } from "../types";
import {
  EmptyState,
  ErrorBanner,
  SectionHeader,
  Skeleton,
  Spinner,
} from "../components/ui";

type Tab = "overview" | "products" | "orders" | "devices";

const TABS: { id: Tab; label: string }[] = [
  { id: "overview", label: "Overview" },
  { id: "products", label: "Products" },
  { id: "orders", label: "Orders" },
  { id: "devices", label: "Devices" },
];

export default function AdminDashboard() {
  const [tab, setTab] = useState<Tab>("overview");
  const [stats, setStats] = useState<DashboardStats | null>(null);
  const [products, setProducts] = useState<AdminProduct[] | null>(null);
  const [orders, setOrders] = useState<Order[] | null>(null);
  const [devices, setDevices] = useState<AdminDevice[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const navigate = useNavigate();

  const token = adminAuth.getToken()!;
  const user = adminAuth.getUser();

  const handleError = (e: unknown) => {
    if (e instanceof ApiError && e.status === 401) {
      adminAuth.clear();
      navigate("/admin/login");
    } else {
      setError(e instanceof Error ? e.message : "Request failed");
    }
  };

  const reload = async () => {
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
      handleError(e);
    }
  };

  useEffect(() => {
    reload();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const logout = () => {
    adminAuth.clear();
    navigate("/admin/login");
  };

  return (
    <div className="space-y-8 fade-in">
      <div className="flex items-end justify-between gap-6">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight text-fg">
            Admin
          </h1>
          <p className="mt-1 text-sm text-fg-muted">
            Signed in as{" "}
            <span className="text-fg">{user?.email ?? "unknown"}</span>
          </p>
        </div>
        <button onClick={logout} className="btn-ghost btn-sm">
          Sign out
        </button>
      </div>

      <nav className="flex gap-1 border-b border-border">
        {TABS.map((t) => (
          <button
            key={t.id}
            onClick={() => setTab(t.id)}
            className={`relative -mb-px border-b-2 px-4 py-2.5 text-sm font-medium transition-colors ${
              tab === t.id
                ? "border-primary text-fg"
                : "border-transparent text-fg-muted hover:text-fg"
            }`}
          >
            {t.label}
          </button>
        ))}
      </nav>

      {error && (
        <ErrorBanner message={error} onDismiss={() => setError(null)} />
      )}

      {tab === "overview" && <OverviewTab stats={stats} />}
      {tab === "products" && (
        <ProductsTab
          token={token}
          products={products}
          onReload={reload}
          onError={handleError}
        />
      )}
      {tab === "orders" && (
        <OrdersTab
          token={token}
          orders={orders}
          onReload={reload}
          onError={handleError}
        />
      )}
      {tab === "devices" && (
        <DevicesTab
          token={token}
          devices={devices}
          onReload={reload}
          onError={handleError}
        />
      )}
    </div>
  );
}

// ── Overview ────────────────────────────────────────────────────────

function OverviewTab({ stats }: { stats: DashboardStats | null }) {
  if (!stats) {
    return (
      <div className="grid grid-cols-2 gap-4 md:grid-cols-4">
        {Array.from({ length: 8 }).map((_, i) => (
          <Skeleton key={i} className="h-24" />
        ))}
      </div>
    );
  }

  const cards = [
    { label: "Customers", value: stats.total_customers },
    { label: "Products", value: stats.total_products },
    { label: "Devices", value: stats.total_devices },
    { label: "Registered", value: stats.devices_registered },
    { label: "Orders", value: stats.total_orders },
    { label: "Pending", value: stats.orders_pending },
    { label: "Paid", value: stats.orders_paid },
    { label: "Fulfilled", value: stats.orders_fulfilled },
  ];

  return (
    <div className="space-y-6">
      <div className="card relative overflow-hidden p-6">
        <div className="absolute inset-y-0 right-0 w-1/3 bg-[radial-gradient(closest-side,rgb(34_211_238_/_0.15),transparent)]" />
        <div className="text-xs font-medium uppercase tracking-wider text-fg-dim">
          Revenue (paid + fulfilled)
        </div>
        <div className="tabular mt-3 text-4xl font-semibold tracking-tight text-fg">
          {formatMoney(stats.revenue_paid_cents, stats.currency)}
        </div>
      </div>

      <div className="grid grid-cols-2 gap-4 md:grid-cols-4">
        {cards.map((c) => (
          <div key={c.label} className="card p-5">
            <div className="text-xs font-medium uppercase tracking-wider text-fg-dim">
              {c.label}
            </div>
            <div className="tabular mt-2 text-2xl font-semibold text-fg">
              {c.value}
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

// ── Products ────────────────────────────────────────────────────────

function ProductsTab({
  token,
  products,
  onReload,
  onError,
}: {
  token: string;
  products: AdminProduct[] | null;
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
    <div className="space-y-6">
      <SectionHeader
        title="Products"
        description="The storefront catalog."
        action={
          <button
            onClick={() => setCreating((v) => !v)}
            className={creating ? "btn-ghost btn-sm" : "btn-primary btn-sm"}
          >
            {creating ? "Cancel" : "New product"}
          </button>
        }
      />

      {creating && (
        <form onSubmit={submit} className="card space-y-5 p-6 fade-in">
          <div className="grid gap-5 md:grid-cols-2">
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
                className="input tabular"
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
                className="input tabular"
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
              className="input min-h-[100px]"
              required
            />
          </div>
          <div className="flex justify-end">
            <button type="submit" className="btn-primary">
              Create product
            </button>
          </div>
        </form>
      )}

      {!products ? (
        <Skeleton className="h-64" />
      ) : products.length === 0 ? (
        <div className="card">
          <EmptyState
            title="No products yet"
            description="Create your first product to populate the storefront."
          />
        </div>
      ) : (
        <div className="card overflow-hidden p-0">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-border bg-surface-2 text-left text-xs font-medium uppercase tracking-wider text-fg-dim">
                <th className="px-5 py-3">Slug</th>
                <th className="px-5 py-3">Name</th>
                <th className="px-5 py-3 text-right">Price</th>
                <th className="px-5 py-3 text-right">Stock</th>
                <th className="px-5 py-3 text-center">Status</th>
                <th className="px-5 py-3"></th>
              </tr>
            </thead>
            <tbody>
              {products.map((p) => (
                <tr
                  key={p.id}
                  className="border-b border-border last:border-b-0 transition-colors hover:bg-surface-2"
                >
                  <td className="px-5 py-3.5 font-mono text-xs text-fg-muted">
                    {p.id}
                  </td>
                  <td className="px-5 py-3.5 text-fg">{p.name}</td>
                  <td className="tabular px-5 py-3.5 text-right text-fg">
                    {formatMoney(p.price_cents, p.currency)}
                  </td>
                  <td className="tabular px-5 py-3.5 text-right text-fg">
                    {p.stock_quantity}
                  </td>
                  <td className="px-5 py-3.5 text-center">
                    {p.active ? (
                      <span className="pill pill-primary">Active</span>
                    ) : (
                      <span className="pill pill-neutral">Inactive</span>
                    )}
                  </td>
                  <td className="px-5 py-3.5 text-right">
                    {p.active && (
                      <button
                        onClick={() => deactivate(p.id)}
                        className="text-xs font-medium text-fg-dim transition-colors hover:text-danger"
                      >
                        Deactivate
                      </button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

// ── Orders ──────────────────────────────────────────────────────────

function OrdersTab({
  token,
  orders,
  onReload,
  onError,
}: {
  token: string;
  orders: Order[] | null;
  onReload: () => void;
  onError: (e: unknown) => void;
}) {
  const [filter, setFilter] = useState<Order["status"] | "all">("all");
  const filtered = !orders
    ? null
    : filter === "all"
      ? orders
      : orders.filter((o) => o.status === filter);

  const update = async (id: string, status: Order["status"]) => {
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
    <div className="space-y-6">
      <SectionHeader title="Orders" description="Filter and manage the queue." />

      <div className="flex gap-2">
        {statuses.map((s) => (
          <button
            key={s}
            onClick={() => setFilter(s)}
            className={`rounded-full px-3.5 py-1.5 text-xs font-medium capitalize transition-colors ${
              filter === s
                ? "bg-primary text-[#052e34]"
                : "border border-border text-fg-muted hover:border-border-strong hover:text-fg"
            }`}
          >
            {s}
          </button>
        ))}
      </div>

      {!filtered ? (
        <Skeleton className="h-64" />
      ) : filtered.length === 0 ? (
        <div className="card">
          <EmptyState
            title={
              filter === "all"
                ? "No orders yet"
                : `No ${filter} orders`
            }
            description="Orders placed through the storefront will appear here."
          />
        </div>
      ) : (
        <div className="card overflow-hidden p-0">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-border bg-surface-2 text-left text-xs font-medium uppercase tracking-wider text-fg-dim">
                <th className="px-5 py-3">Order</th>
                <th className="px-5 py-3">Customer</th>
                <th className="px-5 py-3 text-right">Total</th>
                <th className="px-5 py-3 text-center">Status</th>
                <th className="px-5 py-3 text-right">Created</th>
                <th className="px-5 py-3"></th>
              </tr>
            </thead>
            <tbody>
              {filtered.map((o) => (
                <tr
                  key={o.id}
                  className="border-b border-border last:border-b-0 transition-colors hover:bg-surface-2"
                >
                  <td className="px-5 py-3.5 font-mono text-xs text-fg-muted">
                    {o.id.slice(0, 8)}
                  </td>
                  <td className="px-5 py-3.5">
                    <div className="text-fg">{o.customer_name}</div>
                    <div className="text-xs text-fg-dim">
                      {o.customer_email}
                    </div>
                  </td>
                  <td className="tabular px-5 py-3.5 text-right text-fg">
                    {formatMoney(o.total_cents, o.currency)}
                  </td>
                  <td className="px-5 py-3.5 text-center">
                    <StatusPill status={o.status} />
                  </td>
                  <td className="px-5 py-3.5 text-right text-xs text-fg-dim">
                    {formatDate(o.created_at)}
                  </td>
                  <td className="px-5 py-3.5 text-right">
                    <select
                      value={o.status}
                      onChange={(e) =>
                        update(o.id, e.target.value as Order["status"])
                      }
                      className="rounded-md border border-border bg-bg px-2 py-1 text-xs text-fg outline-none focus:border-primary"
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
        </div>
      )}
    </div>
  );
}

function StatusPill({ status }: { status: Order["status"] }) {
  const map: Record<Order["status"], string> = {
    pending: "pill-neutral",
    paid: "pill-primary",
    fulfilled: "pill-success",
    cancelled: "pill-danger",
  };
  return <span className={`pill ${map[status]}`}>{status}</span>;
}

// ── Devices ─────────────────────────────────────────────────────────

function DevicesTab({
  token,
  devices,
  onReload,
  onError,
}: {
  token: string;
  devices: AdminDevice[] | null;
  onReload: () => void;
  onError: (e: unknown) => void;
}) {
  const [provisioning, setProvisioning] = useState(false);
  const [form, setForm] = useState({ product_id: "", quantity: 5 });
  const [submitting, setSubmitting] = useState(false);

  const provision = async (e: React.FormEvent) => {
    e.preventDefault();
    setSubmitting(true);
    try {
      await adminApi.provisionDevices(token, form);
      setProvisioning(false);
      onReload();
    } catch (e) {
      onError(e);
    } finally {
      setSubmitting(false);
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
    new Set(devices?.map((d) => d.product.id) ?? []),
  );

  return (
    <div className="space-y-6">
      <SectionHeader
        title="Devices"
        description="Provision and manage physical units."
        action={
          <button
            onClick={() => setProvisioning((v) => !v)}
            className={provisioning ? "btn-ghost btn-sm" : "btn-primary btn-sm"}
          >
            {provisioning ? "Cancel" : "Provision"}
          </button>
        }
      />

      {provisioning && (
        <form onSubmit={provision} className="card space-y-5 p-6 fade-in">
          <div className="grid gap-5 md:grid-cols-2">
            <div>
              <label className="label">Product slug</label>
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
              <label className="label">Quantity (1–500)</label>
              <input
                type="number"
                value={form.quantity}
                onChange={(e) =>
                  setForm({ ...form, quantity: Number(e.target.value) })
                }
                className="input tabular"
                min={1}
                max={500}
                required
              />
            </div>
          </div>
          <div className="flex justify-end">
            <button
              type="submit"
              disabled={submitting}
              className="btn-primary"
            >
              {submitting ? (
                <>
                  <Spinner size={14} /> Provisioning…
                </>
              ) : (
                "Provision devices"
              )}
            </button>
          </div>
        </form>
      )}

      {!devices ? (
        <Skeleton className="h-64" />
      ) : devices.length === 0 ? (
        <div className="card">
          <EmptyState
            title="No devices provisioned"
            description="Provision physical units here or run python scripts/seed_shop_data.py."
          />
        </div>
      ) : (
        <div className="card overflow-hidden p-0">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-border bg-surface-2 text-left text-xs font-medium uppercase tracking-wider text-fg-dim">
                <th className="px-5 py-3">ID</th>
                <th className="px-5 py-3">Product</th>
                <th className="px-5 py-3">Owner</th>
                <th className="px-5 py-3 text-center">Status</th>
                <th className="px-5 py-3 text-right">Manufactured</th>
                <th className="px-5 py-3"></th>
              </tr>
            </thead>
            <tbody>
              {devices.map((d) => (
                <tr
                  key={d.id}
                  className="border-b border-border last:border-b-0 transition-colors hover:bg-surface-2"
                >
                  <td className="px-5 py-3.5 font-mono text-xs text-fg">
                    {d.id}
                  </td>
                  <td className="px-5 py-3.5 font-mono text-xs text-fg-muted">
                    {d.product.id}
                  </td>
                  <td className="px-5 py-3.5 text-xs text-fg-muted">
                    {d.owner_email || "—"}
                  </td>
                  <td className="px-5 py-3.5 text-center">
                    {d.status === "registered" && (
                      <span className="pill pill-primary">Registered</span>
                    )}
                    {d.status === "unregistered" && (
                      <span className="pill pill-neutral">Unregistered</span>
                    )}
                    {d.status === "deactivated" && (
                      <span className="pill pill-danger">Deactivated</span>
                    )}
                  </td>
                  <td className="px-5 py-3.5 text-right text-xs text-fg-dim">
                    {formatDate(d.manufactured_at)}
                  </td>
                  <td className="px-5 py-3.5 text-right">
                    <button
                      onClick={() => toggle(d)}
                      className={`text-xs font-medium transition-colors ${
                        d.status === "deactivated"
                          ? "text-fg-muted hover:text-primary"
                          : "text-fg-muted hover:text-danger"
                      }`}
                    >
                      {d.status === "deactivated" ? "Reactivate" : "Deactivate"}
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}