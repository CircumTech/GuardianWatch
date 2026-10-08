import { useEffect, useState } from "react";
import { Link, useParams } from "react-router-dom";
import { api, formatMoney } from "../api";
import type { Product } from "../types";

export default function ProductDetail() {
  const { id } = useParams<{ id: string }>();
  const [product, setProduct] = useState<Product | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!id) return;
    setProduct(null);
    setError(null);
    api
      .getProduct(id)
      .then(setProduct)
      .catch((e) => setError(e.message));
  }, [id]);

  if (error) {
    return (
      <div className="space-y-4">
        <Link to="/" className="text-sm text-gray-400 hover:text-gray-200">
          ← Back to shop
        </Link>
        <div className="card border-danger/40 text-danger text-sm">
          {error}
        </div>
      </div>
    );
  }

  if (!product) {
    return (
      <div className="space-y-6 animate-pulse">
        <div className="h-4 w-32 rounded bg-surface" />
        <div className="h-8 w-64 rounded bg-surface" />
        <div className="h-64 rounded-xl bg-surface" />
      </div>
    );
  }

  const specs = Object.entries(product.specs || {});

  return (
    <div className="space-y-8">
      <Link to="/" className="text-sm text-gray-400 hover:text-gray-200 inline-block">
        ← Back to shop
      </Link>

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-10">
        {/* Left: image placeholder */}
        <div className="aspect-square rounded-2xl border border-border bg-gradient-to-br from-primary/10 to-secondary/10 flex items-center justify-center">
          <div className="h-40 w-40 rounded-full bg-primary/20" />
        </div>

        {/* Right: details */}
        <div className="space-y-6">
          <div className="space-y-3">
            <h1 className="text-3xl font-semibold tracking-tight">
              {product.name}
            </h1>
            {product.tagline && (
              <p className="text-lg text-gray-400">{product.tagline}</p>
            )}
          </div>

          <div className="flex items-baseline gap-3">
            <span className="text-3xl font-semibold">
              {formatMoney(product.price_cents, product.currency)}
            </span>
            <span
              className={`text-sm ${
                product.in_stock ? "text-primary" : "text-danger"
              }`}
            >
              {product.in_stock
                ? `${product.stock_quantity} in stock`
                : "Out of stock"}
            </span>
          </div>

          <p className="text-gray-300 leading-relaxed whitespace-pre-line">
            {product.description}
          </p>

          <button
            disabled={!product.in_stock}
            className="btn-primary w-full py-3"
            onClick={() =>
              alert(
                "Order flow is out of scope for this minimal frontend — POST /orders is tested via Swagger UI.",
              )
            }
          >
            {product.in_stock ? "Buy now" : "Out of stock"}
          </button>
        </div>
      </div>

      {/* Specs */}
      {specs.length > 0 && (
        <section className="space-y-4 pt-6 border-t border-border">
          <h2 className="text-sm font-medium uppercase tracking-wider text-gray-400">
            Specifications
          </h2>
          <dl className="grid grid-cols-1 md:grid-cols-2 gap-x-8 gap-y-3">
            {specs.map(([key, value]) => (
              <div
                key={key}
                className="flex justify-between gap-4 border-b border-border/50 py-2 text-sm"
              >
                <dt className="text-gray-400">{key}</dt>
                <dd className="text-gray-200 text-right">
                  {typeof value === "string"
                    ? value
                    : JSON.stringify(value)}
                </dd>
              </div>
            ))}
          </dl>
        </section>
      )}
    </div>
  );
}