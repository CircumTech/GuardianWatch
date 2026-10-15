# GuardianWrist API

Backend for the GuardianWrist wearable health app: sensor ingestion, coalesced
history, and ML-driven health insights (HRV/stress, AFib, sleep apnea, fever,
fatigue), built to be a **drop-in** backend for the existing Flutter app —
every route, status code, and JSON shape here matches what
`lib/services/api_service.dart` already expects. No Dart changes are required
to point the app at this backend; just update `AppConstants.apiBaseUrl` in
`lib/config/constants.dart`.

## Why this exists

Today, `generateDailyInsights()` in `insight_provider.dart` computes every
insight **on-device**, using simplified rule-based formulas — because the
real trained models (`stress_model.pkl`, `fatigue_model.pkl`,
`fever_detector.pkl`, `afib_detection.tflite`) are Python/TensorFlow
artifacts that can't run in Dart. `POST /insights/generate` is already
defined in `api_service.dart` but never called — this backend is what
makes that endpoint real, serving the actual trained models instead of
their on-device approximations. See **[Upgrading the app to use real
models](#upgrading-the-app-to-use-real-models)** below.

## Quickstart

```bash
python -m venv venv && source venv/bin/activate
pip install -r requirements.txt
cp .env.example .env   # defaults work as-is for local dev (SQLite, no Firebase)
uvicorn app.main:app --reload
```

Open `http://localhost:8000/docs` for interactive Swagger docs. `GET /health`
should show every model as `"loaded"` except `sleep_apnea_model` (see
[The sleep apnea gap](#the-sleep-apnea-gap)).

Local dev uses SQLite by default — zero setup, a single `guardianwrist.db`
file in the project root, tables created automatically on startup. No
Firebase project needed to explore `/docs`, but `POST /auth/token` (and
everything behind it) needs real Firebase Admin credentials — see
[Auth setup](#auth-setup).

To see the app against real-looking data without a physical wristband:

```bash
python scripts/seed_dev_data.py <your-firebase-uid>
python scripts/seed_shop_data.py --devices-per-product 10   # products + lookupable device IDs
```

## Project layout

```
app/
  config.py          Pydantic Settings — every env var, one place
  database.py         async SQLAlchemy engine/session
  security.py          Firebase ID token verification, this API's own JWT,
                       AND the separate admin password hashing / admin JWT
  dependencies.py       get_current_user, get_current_premium_user,
                       get_current_admin, get_model_registry
  models/               SQLAlchemy ORM: User, Reading, Insight, Subscription,
                       Product, Device, Order, AdminUser, AdminAuditLog
  schemas/               Pydantic request/response shapes — field names matched
                         1:1 to the Dart model classes' toJson()/fromJson()
                         where a Dart counterpart exists
  ml/                     ported inference logic from lib/python/*.py, each
                         module preferring the trained model and falling
                         back to the same rule-based formula the Dart app
                         already uses when a model isn't loaded
  services/               business logic: auth, reading ingestion/coalescing,
                         insight orchestration, IAP receipt verification,
                         order creation, Stripe payments, admin audit logging
  routers/                 the actual endpoints — customer-facing, shop/
                         device/order, and admin-only (admin_*.py)
  models_store/            the trained model artifacts (copied from lib/python/models)
alembic/                  DB migrations (see below)
tests/                     pytest suite — 72 tests: ML units, API integration,
                         admin/RBAC boundary, mocked Stripe payment flow
scripts/
  seed_dev_data.py         populate a local DB with realistic fake sensor data
  seed_shop_data.py        populate the shop with sample products + provisioned devices
  create_admin.py          create/reset an admin account (no public signup route)
render.yaml                Render Blueprint — one-click infra (web service + Postgres)
docker-entrypoint.sh        runs migrations, then starts the server
```

## The API contract

Every endpoint below matches `api_service.dart` exactly — method, path,
status code, and response shape (bare JSON array vs. object).

| Method | Path                  | Matches                          | Notes |
|--------|-----------------------|-----------------------------------|-------|
| POST   | `/auth/token`          | `exchangeToken`                   | Firebase ID token → this API's JWT |
| POST   | `/readings`            | `uploadReadings`                  | 201, batch of partial `SensorData` |
| GET    | `/readings`            | `fetchHistory`                    | `page` is **0-indexed**, matching the Dart default |
| GET    | `/insights/latest`     | `fetchInsights`                   | bare array |
| POST   | `/insights/generate`   | `generateInsights`                | bare array — see [Why this exists](#why-this-exists) |
| POST   | `/insights/save`       | `saveInsights`                    | 201, persists client-computed insights |
| POST   | `/subscription/verify` | `verifyReceipt`                   | 200 on any resolved outcome (active/expired/invalid) |

Plus a few additions with no existing Dart caller, each documented in its
router with what it's for and why it's safe to add: `GET /health`,
`GET /me`, `PATCH /me`, `GET /readings/summary`, `POST /ecg/analyze`.

## The company site & shop layer

Added for the public **Circum** company site (Circum is the company;
GuardianWatch/GuardianWrist is its flagship product line — keep that
distinction in whatever frontend copy you write against this API).

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/products` | public | Shop catalog (active products only) |
| GET | `/products/{id}` | public | Product detail page |
| GET | `/devices/lookup/{device_id}` | public | "Look up your device" — the special-id authenticity/warranty check |
| POST | `/devices/register` | customer | Claim a device — the cloud half of first-pair registration |
| POST | `/devices/{id}/reset` | customer | Unlink a device (the cloud counterpart to a long-press power-button reset) |
| GET | `/devices/mine` | customer | A signed-in customer's own devices |
| POST | `/orders` | public (guest checkout) | Create a pending order |
| POST | `/orders/{id}/checkout` | public | Get a Stripe-hosted payment link for that order |
| GET | `/orders/{id}?email=` | public | Order confirmation / tracking — requires the checkout email to match |
| POST | `/webhooks/stripe` | Stripe signature | Payment confirmation — see [Payments](#payments-stripe) |

## Payments (Stripe)

Checkout flow: `POST /orders` (capture shipping + customer info) →
`POST /orders/{id}/checkout` (get a Stripe Checkout URL) → redirect the
browser there → Stripe redirects back to `FRONTEND_URL/order-confirmation`
on success or `FRONTEND_URL/checkout?cancelled=true` on cancel.

The order is only ever marked `paid` by the `/webhooks/stripe` handler —
never by the success-page redirect, which isn't trustworthy on its own
(it can be hit without a real payment, by mistake or on purpose). The
webhook double-checks the amount Stripe actually collected against the
order's expected total before marking it paid, on top of verifying
Stripe's signature.

This uses **Stripe Checkout** (Stripe's own hosted payment page), not a
custom card form — this app never sees, handles, or stores a card
number, which keeps it out of the heavy end of PCI-DSS scope.

**Setup:**
1. Get test-mode keys from the [Stripe dashboard](https://dashboard.stripe.com/test/apikeys) → set `STRIPE_SECRET_KEY`.
2. Register a webhook endpoint at `<your-api>/webhooks/stripe` for the
   `checkout.session.completed` event → set `STRIPE_WEBHOOK_SECRET`. For
   local testing, use the [Stripe CLI](https://stripe.com/docs/stripe-cli)'s `stripe listen --forward-to localhost:8000/webhooks/stripe` instead.
3. Set `FRONTEND_URL` to wherever the company site is actually deployed.

**Not verified end-to-end**: this sandbox has no network route to
`api.stripe.com` (see [Testing constraints](#testing-constraints) below)
— the SDK usage (method names, exception types, request shape) is
confirmed correct against the installed `stripe` package, and every piece
of *this app's own logic* (order lookup, status guards, signature
verification, the amount-mismatch check) is covered by mocked tests in
`tests/test_payments.py`. Test against real Stripe test-mode payments
before going live.

## The admin panel — architecture & security boundary

A second, deliberately separate authentication system for internal
staff — separate table (`AdminUser`, keyed by email+password, not
Firebase), separate JWT secret (`ADMIN_JWT_SECRET_KEY`), separate
dependency (`get_current_admin`, not `get_current_user`). See
`models/admin_user.py`'s docstring for the reasoning: a customer session
should be *structurally* incapable of passing as an admin session, not
just logically blocked by a permission check that could have a bug in it.

**What admins can manage:** products (create/edit/stock/deactivate),
devices (provision new units, view registration status, deactivate lost
units), orders (view, update fulfillment status), and a dashboard of
aggregate counts/revenue.

**What admins cannot see, by design:** any individual user's health
data. There is no admin endpoint anywhere that returns a `Reading` or an
`Insight` — that capability was never built, rather than built-and-then-
permission-gated, which is a stronger guarantee than a check that could
be forgotten on some future route. `tests/test_admin.py::TestRestrictionWall::test_no_admin_endpoint_exposes_health_readings`
enforces this by scanning the live OpenAPI schema for `/admin/*` paths
that look health-related, so it keeps checking every future admin route
too, not just the ones that existed when the test was written.

Device management *does* show a device's owner email — a support agent
troubleshooting a specific unit has a legitimate need to know who to
contact. That's the one deliberate exception to "admins see nothing
customer-identifying," and it's scoped to contact info, never health data.

**Creating an admin account** — no public signup endpoint exists, on purpose:
```bash
python scripts/create_admin.py owner@circum.dev "Your Name"
```

**Audit log**: every admin mutation (product changes, order status
updates, device provisioning/deactivation) is recorded in
`admin_audit_log` — who, what, when — and there's no update/delete route
for that table. `GET /admin/audit-log` shows the trail.

## ML models — what's real, what's fallback

| Insight | Model | File | Status |
|---|---|---|---|
| HRV / stress | RandomForestRegressor | `stress_model.pkl` | loaded |
| Fatigue | LinearRegression | `fatigue_model.pkl` | loaded |
| Fever | IsolationForest | `fever_detector.pkl` | loaded |
| AFib | 1D CNN | `afib_detection.tflite` | loaded (via `ai-edge-litert`, ~58MB — see below) |
| Sleep apnea | XGBoost | *(not provided)* | rule-based fallback — see next section |

Every `ml/*.py` module is structured the same way: try the trained model,
fall back to the exact rule-based formula already shipping in
`insight_model_service.dart` if the model isn't loaded or a prediction
fails. Nothing 500s because a `.pkl` is missing.

**AFib serving choice:** `afib_detection.h5` (Keras, 833KB) would need the
full `tensorflow` package (typically 500MB+, slow cold starts). The
`.tflite` export (80KB) runs through `ai-edge-litert`
(Google's actively-maintained successor to `tflite-runtime`, ~58MB) —
verified working in this build: loads the model, confirms the expected
`(1, 2500, 1)` input / `(1, 1)` output shape, and runs real inference.
Much better fit for a Cloud Run container than pulling in TensorFlow for
one model.

### The sleep apnea gap

`sleep_apena.py` defines training and prediction for an XGBoost classifier,
but `sleep_apnea_model.pkl` / `sleep_apnea_scaler.pkl` were never included
in the uploaded project — only the training code was. `ml/sleep_apnea.py`
still implements the identical feature engineering (`compute_odi` is a
verbatim port), scored through the same odi→risk_score→risk_level bands
`insight_model_service.dart` already uses. **To close the gap:** run
`lib/python/sleep_apena.py`'s training routine, drop the two resulting
`.pkl` files into `app/models_store/`, restart — `ModelRegistry` picks
them up automatically. No code changes needed anywhere.

### A bug found and fixed along the way

`fever_infection.py`'s original probability formula branched on the sign
of the IsolationForest score and got the non-anomalous branch backwards —
a **strongly normal** reading (`decision_function` score of `+3`) worked
out to a **95% fever probability**. Verified numerically while porting it
(see `ml/fever.py`'s docstring and `tests/test_ml_fever.py`'s regression
test); fixed to a single monotonic formula, which is what the buggy
version's *other* branch already computed correctly. This only affects
the human-facing probability display — the anomaly classification itself
(`is_suspected`) was never affected, since it comes from the model's own
`.predict()`, not this formula.

## Data model notes

**Raw readings vs. coalesced history.** `SensorData` events arrive from
the wristband as partial single-field updates — one BLE notification sets
`heart_rate`, the next sets `spo2`, etc. (see `ble_service.dart::_parseBytes`).
The `readings` table stores them exactly as they arrive. `GET /readings`
walks them chronologically with a carry-forward merge (5-minute staleness
window, throttled to one emitted record per minute) to produce the
complete `HealthRecord` rows the app expects — see
`services/reading_service.py::_coalesce` and its test file for the exact
rules. This also happens to fix a real gap: the Dart app's own local
merge (`ble_provider.dart`) only inserts a complete record when a
*single* BLE event has all three fields at once, which realistically only
ever happens via the mock-data path, not real hardware.

**RR intervals for HRV/AFib.** Individual ECG samples don't carry their
own timestamp over BLE — only the batch does. `_rr_intervals_from_readings`
in `insight_service.py` uses each batch's arrival time as a stand-in for
peak timing, mirroring `addEcgSample()`'s existing approximation in the
Dart app rather than assuming an unverified hardware sample rate. If you
confirm a fixed ECG sample rate from the Arduino firmware, this can be
upgraded to derive RR intervals from intra-batch sample spacing directly,
which would be materially more precise.

**Resting HR trend.** Built server-side as one value per calendar day (UTC) —
the day's minimum heart rate — rather than the Dart app's 30-reading
rolling buffer of *every* incoming HR sample (which resets on app
restart and doesn't distinguish resting from active). Daily-minimum is
the standard proxy real wearables use, and only feasible server-side where
full history is available.

## Auth setup

Two layers:

1. **Firebase ID token verification** — proves the person is who Firebase
   says. Set `FIREBASE_CREDENTIALS_PATH` to a service-account JSON key, or
   leave it unset to use Application Default Credentials (the right choice
   on Cloud Run with a service account attached).
2. **This API's own JWT** — minted by `POST /auth/token` after step 1
   succeeds, checked on every other request. Set a real `JWT_SECRET_KEY`
   for anything beyond local dev:
   ```bash
   python -c "import secrets; print(secrets.token_urlsafe(48))"
   ```

`JWT_EXPIRE_MINUTES` defaults to 30 days. The Dart app has no refresh flow
today — it calls `exchangeToken()` once at sign-in and reuses the JWT
until it expires or the person signs out, so this is set generously long
to avoid mid-session 401s. Firebase ID tokens themselves auto-refresh
client-side hourly; a natural resilience improvement would be having the
app silently re-call `exchangeToken()` periodically using that still-valid
Firebase session, rather than only at sign-in.

## IAP receipt verification — untested against real stores

`services/receipt_service.py` implements Apple and Google Play receipt
verification against each platform's documented API. **This sandbox's
network egress doesn't reach `buy.itunes.apple.com` or
`androidpublisher.googleapis.com`**, so unlike everything else in this
project, it hasn't been exercised end-to-end — test it against real
sandbox receipts before relying on it.

One related gap: `iap_service.dart::_onPurchaseUpdate` sends `receipt` +
`product_id` to `/subscription/verify` but never a `platform` flag, even
though `defaultTargetPlatform` is available in the same file. The
endpoint handles this today by trying Apple then Google when `platform`
is absent — but sending it explicitly is a trivial, backward-compatible
one-line fix that removes the guesswork:
```dart
platform: defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android',
```

## Database & migrations

Local dev: SQLite, tables auto-created on startup (`ENV=development`
only). Production: point `DATABASE_URL` at Postgres and use Alembic —
auto-create is deliberately skipped outside development.

```bash
# after changing a model:
alembic revision --autogenerate -m "describe the change"
# check the generated file for `app.utils.db_types.UTCDateTime` columns —
# autogenerate doesn't add the `import app.utils.db_types` line for
# custom types automatically; add it by hand if it's missing, or the
# migration will fail on import.
alembic upgrade head
```

**Why `UTCDateTime` instead of plain `DateTime(timezone=True)`:** SQLite
has no native timestamp type and silently drops tzinfo on read-back even
though values are written with a UTC offset — confirmed while building
this (a `GET /readings` call threw `can't compare offset-naive and
offset-aware datetimes` the first time real data flowed through it).
PostgreSQL via `asyncpg` doesn't have this problem, but since local dev
defaults to SQLite, every timestamp column uses the `UTCDateTime` type in
`app/utils/db_types.py`, which normalizes at the type level — fixed once,
everywhere, rather than at every call site that reads a timestamp back
out. Worth knowing if you add a new datetime column.

## Running tests

```bash
pytest                 # 72 tests: ML units, API integration, admin/RBAC, mocked payments
```

ML tests cover the insufficient-data thresholds, rule-based fallback math
(with hand-verified expected outputs), the fever probability regression
test, and end-to-end runs through the actual trained model files. API
tests cover the full auth → ingest → coalesce → generate-insights flow,
the shop (products/devices/orders) flow, and admin auth + RBAC boundary
enforcement, all against an isolated in-memory SQLite DB per test.
Payment tests mock the Stripe SDK to verify this app's own checkout and
webhook logic (see [Testing constraints](#testing-constraints-in-this-build-environment)
for why they're mocked rather than live).

One thing worth knowing if you extend the test suite: `auth_service.py`
calls Firebase verification through `from app import security` (module
reference) rather than `from app.security import verify_firebase_id_token`
(direct name import) specifically so `unittest.mock.patch
("app.security.verify_firebase_id_token")` reliably intercepts it
regardless of module import order — a direct name import binds its own
reference at import time that a later patch on the origin module won't
touch. This bit the first draft of the integration tests; worth keeping
the pattern if you add new service-layer calls to `security.py`.

## Deployment (Render)

```bash
# 1. Push this repo somewhere Render can see it, then:
#    Render dashboard → New + → Blueprint → point at the repo.
#    render.yaml provisions the web service + a managed Postgres
#    database and wires DATABASE_URL between them automatically.

# 2. Set the secrets Blueprint can't auto-fill (Render dashboard →
#    Environment, on the guardianwrist-api service):
#      STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET, FRONTEND_URL,
#      CORS_ORIGINS, and either FIREBASE_CREDENTIALS_PATH (pointing at a
#      Secret File you upload) or nothing at all if the service account
#      attached to the Render service already has the right Firebase
#      permissions via Application Default Credentials.

# 3. Migrations run automatically on every deploy — see
#    docker-entrypoint.sh. Nothing extra to run manually.

# 4. Create your first admin account via the Render shell
#    (dashboard → guardianwrist-api → Shell):
python scripts/create_admin.py owner@circum.dev "Your Name"
```

Also runs unchanged on Cloud Run or any other container platform that
sets `$PORT` — `render.yaml` is Render-specific, but the `Dockerfile`
itself isn't.

For local Postgres instead of SQLite: `docker compose up`.

## Testing constraints in this build environment

Two integrations were implemented against their documented APIs and
tested as thoroughly as possible from here, but couldn't be exercised
against the real, live third-party service:

- **Stripe** — this sandbox has no network route to `api.stripe.com`.
  SDK usage is confirmed correct; `tests/test_payments.py` mocks the SDK
  calls to verify this app's own logic. Test with real Stripe test-mode
  payments before launch.
- **Apple/Google receipt verification** (`services/receipt_service.py`,
  pre-existing) — same constraint, same caveat, noted in its own docstring.

Everything else in this README — the full customer flow, the admin
panel, the RBAC boundary, stock/order management, the ML pipeline — has
been run for real against this codebase (72 automated tests, plus manual
end-to-end smoke runs) as part of building it, not just written and
assumed to work.

## Suggested next steps

- **Wire up the real models.** Change `generateDailyInsights()` in
  `insight_provider.dart` to call `_api.generateInsights()` instead of
  computing on-device — this is the one-line change that makes the whole
  ML layer in this backend actually reachable from the app. See
  [Why this exists](#why-this-exists).
- Train and drop in the missing sleep apnea model (see [The sleep apnea
  gap](#the-sleep-apnea-gap)).
- Send `platform` explicitly on receipt verification (see
  [IAP](#iap-receipt-verification--untested-against-real-stores)).
- Test IAP verification and Stripe against real sandbox/test-mode
  transactions (see [Testing constraints](#testing-constraints-in-this-build-environment)).
- The public Circum company site and the admin panel frontend are the
  next phase — this API is what both of them are built against.
- If raw ECG volume grows significantly, consider a dedicated time-series
  store (TimescaleDB on Postgres, or InfluxDB) for the `ecg_mv` column
  instead of JSON — not necessary at current wearable-device data volumes.

## Upgrading the app to use real models

Right now: `generateDailyInsights()` (Dart, on-device rules) →
`POST /insights/save`. Available now: `POST /insights/generate` (this
backend, real trained models) → same `Insight` shape, drop-in compatible.
Swapping the call in `insight_provider.dart` is the entire migration —
everything downstream (the insights screen, the premium paywall flags,
severity-based styling) already expects exactly this shape.
