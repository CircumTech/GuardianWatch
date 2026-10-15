from app.routers import (
    auth, ecg, health, insights, readings, subscription, users,
    products, devices, orders, webhooks,
    admin_auth, admin_products, admin_devices, admin_orders, admin_dashboard,
)

__all__ = [
    "auth", "ecg", "health", "insights", "readings", "subscription", "users",
    "products", "devices", "orders", "webhooks",
    "admin_auth", "admin_products", "admin_devices", "admin_orders", "admin_dashboard",
]
