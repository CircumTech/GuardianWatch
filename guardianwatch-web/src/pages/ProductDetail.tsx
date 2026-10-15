import { useEffect, useState } from "react";
import { Link, useParams } from "react-router-dom";
import { api, formatMoney } from "../api";
import type { Product } from "../types";
import { ErrorBanner, Skeleton } from "../components/ui";

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
      <div className="space-y-6 fade-in">
        <BackLink />
        <ErrorBanner message={error} />
      </div>
    );
  }

  if (!product) {
    return (
      <div className="space-y-6 fade-in">
        <BackLink />
        <div className="grid gap-10 lg:grid-cols-2">
          <Skeleton className="aspect-square rounded-2xl" />
          <div className="space-y-4">
            <Skeleton className="h-8 w-3/4" />
            <Skeleton className="h-5 w-1/2" />
            <Skeleton className="h-10 w-40" />
            <Skeleton className="h-24 w-full" />
          </div>
        </div>
      </div>
    );
  }

  const specs = Object.entries(product.specs || {});

  return (
    <div className="space-y-10 fade-in">
      <BackLink />

      <div className="grid gap-12 lg:grid-cols-2">
        {/* Image */}
        <div className="relative aspect-square overflow-hidden rounded-2xl border border-border bg-gradient-to-br from-primary/10 via-surface to-secondary/10">
          <div className="absolute inset-0 flex items-center justify-center">
            <div className="h-48 w-48 rounded-full bg-primary/15" />
          </div>
        </div>

        {/* Info */}
        <div className="flex flex-col gap-8 py-2">
          <div className="space-y-4">
            <div className="flex items-center gap-3">
              <span className="font-mono text-xs text-fg-dim">{product.id}</span>
              {product.in_stock ? (
                <span className="pill pill-success">
                  {product.stock_quantity} in stock
                </span>
              ) : (
                <span className="pill pill-danger">Out of stock</span>
              )}
            </div>

            <h1 className="text-3xl font-semibold tracking-tight text-fg md:text-4xl">
              {product.name}
            </h1>

            {product.tagline && (
              <p className="text-lg text-fg-muted">{product.tagline}</p>
            )}
          </div>

          <div className="tabular text-3xl font-semibold text-fg">
            {formatMoney(product.price_cents, product.currency)}
          </div>

          <p className="whitespace-pre-line text-base leading-relaxed text-fg-muted">
            {product.description}
          </p>

          <div className="flex gap-3 pt-2">
            <button
              disabled={!product.in_stock}
              className="btn-primary flex-1 py-3"
              onClick={() =>
                alert(
                  "Checkout flow tested via Swagger UI. Frontend order form is out of scope for this MVP.",
                )
              }
            >
              {product.in_stock ? "Buy now" : "Out of stock"}
            </button>
          </div>
        </div>
      </div>

      {/* Specs */}
      {specs.length > 0 && (
        <section className="space-y-5 border-t border-border pt-10">
          <h2 className="text-sm font-medium uppercase tracking-wider text-fg-dim">
            Specifications
          </h2>
          <dl className="grid gap-x-12 gap-y-1 md:grid-cols-2">
            {specs.map(([key, value]) => (
              <div
                key={key}
                className="flex items-start justify-between gap-6 border-b border-border py-3.5 text-sm"
              >
                <dt className="text-fg-muted">{key}</dt>
                <dd className="text-right text-fg">
                  {typeof value === "string" ? value : JSON.stringify(value)}
                </dd>
              </div>
            ))}
          </dl>
        </section>
      )}
    </div>
  );
}

function BackLink() {
  return (
    <Link
      to="/"
      className="inline-flex items-center gap-1.5 text-sm text-fg-muted transition-colors hover:text-fg"
    >
      <svg
        width="14"
        height="14"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        strokeWidth="2"
      >
        <path d="M19 12H5M12 19l-7-7 7-7" />
      </svg>
      Back to shop
    </Link>
  );
}