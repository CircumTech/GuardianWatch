import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { api, formatMoney } from "../api";
import type { Product } from "../types";

export default function Home() {
  const [products, setProducts] = useState<Product[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    api
      .getProducts()
      .then(setProducts)
      .catch((e) => setError(e.message));
  }, []);

  return (
    <div className="space-y-10">
      {/* Hero */}
      <section className="rounded-2xl border border-border bg-surface p-10">
        <div className="max-w-2xl space-y-4">
          <div className="inline-flex items-center gap-2 rounded-full border border-border bg-bg px-3 py-1 text-xs text-gray-400">
            <span className="inline-block h-1.5 w-1.5 rounded-full bg-primary" />
            Now shipping
          </div>
          <h1 className="text-4xl font-semibold tracking-tight">
            Health signals, on your wrist.
          </h1>
          <p className="text-gray-400 leading-relaxed">
            Continuous heart rate, oxygen, temperature, and ECG.
            On-device insights that explain trends — not just plot them.
            Wellness indicators, not medical diagnoses.
          </p>
        </div>
      </section>

      {/* Grid */}
      <section className="space-y-4">
        <h2 className="text-sm font-medium uppercase tracking-wider text-gray-400">
          Products
        </h2>

        {error && (
          <div className="card border-danger/40 text-danger text-sm">
            Failed to load products: {error}
          </div>
        )}

        {!products && !error && (
          <div className="grid grid-cols-1 md:grid-cols-2 gap-5">
            {[0, 1].map((i) => (
              <div
                key={i}
                className="h-72 animate-pulse rounded-xl border border-border bg-surface"
              />
            ))}
          </div>
        )}

        {products && products.length === 0 && (
          <div className="card text-center text-sm text-gray-400">
            No products yet. Run{" "}
            <code className="text-gray-200">python scripts/seed_shop_data.py</code>{" "}
            to add the demo catalog.
          </div>
        )}

        {products && products.length > 0 && (
          <div className="grid grid-cols-1 md:grid-cols-2 gap-5">
            {products.map((p) => (
              <Link
                key={p.id}
                to={`/products/${p.id}`}
                className="group card hover:border-primary/50 transition-colors"
              >
                <div className="aspect-video rounded-lg bg-gradient-to-br from-primary/10 to-secondary/10 mb-4 flex items-center justify-center">
                  <div className="h-16 w-16 rounded-full bg-primary/20" />
                </div>
                <div className="flex items-start justify-between gap-3">
                  <div className="space-y-1">
                    <h3 className="text-lg font-medium group-hover:text-primary transition-colors">
                      {p.name}
                    </h3>
                    {p.tagline && (
                      <p className="text-sm text-gray-400 line-clamp-2">
                        {p.tagline}
                      </p>
                    )}
                  </div>
                  <div className="text-right shrink-0">
                    <div className="text-lg font-semibold">
                      {formatMoney(p.price_cents, p.currency)}
                    </div>
                    <div
                      className={`text-xs ${
                        p.in_stock ? "text-primary" : "text-danger"
                      }`}
                    >
                      {p.in_stock ? `${p.stock_quantity} in stock` : "Sold out"}
                    </div>
                  </div>
                </div>
              </Link>
            ))}
          </div>
        )}
      </section>
    </div>
  );
}