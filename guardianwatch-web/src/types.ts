export interface Product {
  id: string;
  name: string;
  tagline: string | null;
  description: string;
  price_cents: number;
  currency: string;
  image_url: string | null;
  specs: Record<string, unknown>;
  stock_quantity: number;
  in_stock: boolean;
}

export interface AdminProduct extends Product {
  active: boolean;
  created_at: string;
  updated_at: string;
}

export interface DeviceLookup {
  id: string;
  product: Product;
  status: "unregistered" | "registered" | "deactivated";
  firmware_version: string | null;
  registered_at: string | null;
  warranty_months: number;
  warranty_active: boolean;
}

export interface AdminDevice extends DeviceLookup {
  owner_user_id: string | null;
  owner_email: string | null;
  manufactured_at: string;
}

export interface Order {
  id: string;
  product: Product;
  quantity: number;
  unit_price_cents: number;
  total_cents: number;
  currency: string;
  customer_name: string;
  customer_email: string;
  shipping_address: Record<string, string>;
  user_id: string | null;
  status: "pending" | "paid" | "fulfilled" | "cancelled";
  created_at: string;
  paid_at: string | null;
  fulfilled_at: string | null;
  cancelled_at: string | null;
}

export interface DashboardStats {
  total_customers: number;
  total_products: number;
  total_devices: number;
  devices_registered: number;
  devices_unregistered: number;
  total_orders: number;
  orders_pending: number;
  orders_paid: number;
  orders_fulfilled: number;
  revenue_paid_cents: number;
  currency: string;
}

export interface AdminUser {
  id: string;
  email: string;
  display_name: string;
  role: string;
  is_active: boolean;
}