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
```

## Project layout

```
app/
  config.py          Pydantic Settings — every env var, one place
  database.py         async SQLAlchemy engine/session
  security.py          Firebase ID token verification + this API's own JWT
  dependencies.py       get_current_user, get_current_premium_user, get_model_registry
  models/               SQLAlchemy ORM: User, Reading, Insight, Subscription
  schemas/               Pydantic request/response shapes — field names matched
                         1:1 to the Dart model classes' toJson()/fromJson()
  ml/                     ported inference logic from lib/python/*.py, each
                         module preferring the trained model and falling
                         back to the same rule-based formula the Dart app
                         already uses when a model isn't loaded
  services/               business logic: auth, reading ingestion/coalescing,
                         insight orchestration, IAP receipt verification
  routers/                 the actual endpoints
  models_store/            the trained model artifacts (copied from lib/python/models)
alembic/                  DB migrations (see below)
tests/                     pytest suite — 44 tests, ML units + API integration
scripts/seed_dev_data.py   populate a local DB with realistic fake sensor data
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
pytest                 # 44 tests: ML unit tests + API integration tests
```

ML tests cover the insufficient-data thresholds, rule-based fallback math
(with hand-verified expected outputs), the fever probability regression
test, and end-to-end runs through the actual trained model files. API
tests cover the full auth → ingest → coalesce → generate-insights flow
against an isolated in-memory SQLite DB per test, with Firebase
verification mocked.

One thing worth knowing if you extend the test suite: `auth_service.py`
calls Firebase verification through `from app import security` (module
reference) rather than `from app.security import verify_firebase_id_token`
(direct name import) specifically so `unittest.mock.patch
("app.security.verify_firebase_id_token")` reliably intercepts it
regardless of module import order — a direct name import binds its own
reference at import time that a later patch on the origin module won't
touch. This bit the first draft of the integration tests; worth keeping
the pattern if you add new service-layer calls to `security.py`.

## Deployment (Cloud Run)

Matches the `*.run.app` placeholder already in `AppConstants.apiBaseUrl`
(`constants.dart`).

```bash
docker build -t guardianwrist-api .
gcloud run deploy guardianwrist-api \
  --image gcr.io/YOUR_PROJECT/guardianwrist-api \
  --set-env-vars ENV=production,DATABASE_URL=...,JWT_SECRET_KEY=...,FIREBASE_PROJECT_ID=guardianwatch-b1972 \
  --service-account YOUR_SERVICE_ACCOUNT
```

The `--service-account` flag matters even though it's easy to skip: it's
what lets `FIREBASE_CREDENTIALS_PATH` stay unset in production and still
have `firebase_admin` authenticate via Application Default Credentials.

Run `alembic upgrade head` against the production database before or
during deploy (a Cloud Run Job, or a CI/CD migration step) — the API
image itself won't create tables in production mode.

For local Postgres instead of SQLite: `docker compose up`.

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
- Test IAP verification against real Apple/Google sandbox receipts.
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
