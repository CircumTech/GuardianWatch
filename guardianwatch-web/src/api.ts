import type {
  AdminDevice,
  AdminProduct,
  AdminUser,
  DashboardStats,
  DeviceLookup,
  Order,
  Product,
} from "./types";

const BASE_URL =
  (import.meta.env.VITE_API_URL as string) || "http://localhost:8000";

// ── Error handling ────────────────────────────────────────────────────────

export class ApiError extends Error {
  status: number;
  detail?: string;

  constructor(status: number, message: string, detail?: string) {
    super(message);
    this.status = status;
    this.detail = detail;
    this.name = "ApiError";
  }
}

async function request<T>(
  path: string,
  options: RequestInit & { token?: string } = {},
): Promise<T> {
  const { token, headers, ...rest } = options;

  const finalHeaders: Record<string, string> = {
    "Content-Type": "application/json",
    ...(headers as Record<string, string> | undefined),
  };

  if (token) {
    finalHeaders.Authorization = `Bearer ${token}`;
  }

  const response = await fetch(`${BASE_URL}${path}`, {
    ...rest,
    headers: finalHeaders,
  });

  if (response.status === 204) {
    return undefined as T;
  }

  const text = await response.text();
  const data = text ? JSON.parse(text) : null;

  if (!response.ok) {
    const detail =
      typeof data?.detail === "string"
        ? data.detail
        : Array.isArray(data?.detail)
          ? data.detail.map((d: any) => d.msg).join(", ")
          : undefined;
    throw new ApiError(
      response.status,
      detail || `HTTP ${response.status}`,
      detail,
    );
  }

  return data as T;
}

// ── Public endpoints ──────────────────────────────────────────────────────

export const api = {
  getProducts: () => request<Product[]>("/products"),

  getProduct: (id: string) => request<Product>(`/products/${id}`),

  lookupDevice: (id: string) =>
    request<DeviceLookup>(`/devices/lookup/${encodeURIComponent(id)}`),
};

// ── Admin endpoints ───────────────────────────────────────────────────────

export const adminApi = {
  login: async (email: string, password: string) => {
    const res = await request<{
      access_token: string;
      admin: AdminUser;
    }>("/admin/auth/login", {
      method: "POST",
      body: JSON.stringify({ email, password }),
    });
    return res;
  },

  me: (token: string) => request<AdminUser>("/admin/auth/me", { token }),

  stats: (token: string) =>
    request<DashboardStats>("/admin/dashboard/stats", { token }),

  // Products
  listProducts: (token: string) =>
    request<AdminProduct[]>("/admin/products?limit=200", { token }),

  createProduct: (
    token: string,
    body: Partial<AdminProduct> & { id: string },
  ) =>
    request<AdminProduct>("/admin/products", {
      method: "POST",
      token,
      body: JSON.stringify(body),
    }),

  updateProduct: (
    token: string,
    id: string,
    body: Partial<AdminProduct>,
  ) =>
    request<AdminProduct>(`/admin/products/${id}`, {
      method: "PATCH",
      token,
      body: JSON.stringify(body),
    }),

  deactivateProduct: (token: string, id: string) =>
    request<void>(`/admin/products/${id}`, { method: "DELETE", token }),

  // Orders
  listOrders: (token: string) =>
    request<Order[]>("/admin/orders?limit=200", { token }),

  updateOrderStatus: (
    token: string,
    id: string,
    status: Order["status"],
  ) =>
    request<Order>(`/admin/orders/${id}/status`, {
      method: "PATCH",
      token,
      body: JSON.stringify({ status }),
    }),

  // Devices
  listDevices: (token: string) =>
    request<AdminDevice[]>("/admin/devices?limit=200", { token }),

  provisionDevices: (
    token: string,
    body: { product_id: string; quantity: number; warranty_months?: number },
  ) =>
    request<AdminDevice[]>("/admin/devices/provision", {
      method: "POST",
      token,
      body: JSON.stringify(body),
    }),

  deactivateDevice: (token: string, id: string) =>
    request<AdminDevice>(`/admin/devices/${id}/deactivate`, {
      method: "POST",
      token,
    }),

  reactivateDevice: (token: string, id: string) =>
    request<AdminDevice>(`/admin/devices/${id}/reactivate`, {
      method: "POST",
      token,
    }),
};

// ── Money formatting ──────────────────────────────────────────────────────

export function formatMoney(cents: number, currency = "USD"): string {
  return new Intl.NumberFormat("en-US", {
    style: "currency",
    currency,
  }).format(cents / 100);
}

export function formatDate(iso: string | null | undefined): string {
  if (!iso) return "—";
  return new Date(iso).toLocaleString();
}