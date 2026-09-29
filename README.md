# Docker Web Development Environment

This folder defines the Docker containers for your web development workflow. Docker through this `ops` project is the only supported local development path.

Your project source lives outside this folder:

```txt
../ui-astro
../api
```

This Docker setup lives here:

```txt
../ops
```

## Containers

The development Compose stack has four containers:

- `dev-ui`: runs the Astro UI (`../ui-astro`) in development mode via `astro dev`.
- `dev-api`: runs the Elysia API with Bun, SQLite, and Redis (rate limiting).
- `dev-worker`: processes the WhatsApp outgoing message queue from Redis.
- `redis`: shared Redis service for API rate limiting, tokens, local test runs, and the WhatsApp job queue.

Production local testing lives in `docker-compose.prod.yml`:

- `prod-api`: builds and runs the Elysia API in production mode, serving Astro static files.
- `prod-worker`: processes the WhatsApp outgoing message queue (reuses the prod-api image).
- `redis`: shared Redis service for the production API container and the WhatsApp job queue.

All custom images use Debian Bookworm slim bases. The API and worker images use `oven/bun:1-debian`; `dev-ui` uses `node:22-slim` so the dev server and the production Astro build run on the same Node major.

## How The Containers Connect

`dev-ui` mounts the Astro app:

```txt
../ui-astro -> /peonveloz/ui-astro
```

`dev-api` mounts your API project:

```txt
../api -> /peonveloz/api
```

`prod-api` uses the API folder as its Docker build context from `docker-compose.prod.yml`. The Astro bundle is built as part of the API image (multi-stage build).

The result:

- edit code directly on your host machine
- run API tests from the host or inside `dev-api`
- run the integrated dev stack with `dev-ui` and `dev-api` together
- regenerate ui-astro API types from the fresh `dev-api` Swagger schema during startup
- build/run the production image with `prod-api` (API + Astro static files)

Runtime configuration lives in this folder:

- `.env.development` is the local source of truth for Docker dev runs.
- `.env.production` is the local source of truth for production-like local runs.
- `.env.development.example` and `.env.production.example` document the required variables.
- `api/.env` is intentionally not used by the supported dev workflow; the API reads its configuration from `ops/.env.development`.
- `ui-astro/.env` is optional and only for UI overrides such as `PUBLIC_API_URL`; see `ui-astro/.env.example`.

## Quick Start

Copy the example environment files and fill the local Docker values:

```sh
cp .env.development.example .env.development
cp .env.production.example .env.production
```

Clone your project repositories:

```sh
cd ..
git clone git@github.com:YOUR_USER/peonveloz-ui-astro.git ui-astro
git clone git@github.com:YOUR_USER/peonveloz-api.git api
```

Start the integrated app stack:

```sh
make up
```

`dev-ui` binds host port `4321`. If a host `astro dev` is still running, stop it first (`cd ../ui-astro && npx astro dev stop`), otherwise the port is already taken.

This starts/recreates:

- `dev-api`
- `dev-ui`
- `dev-worker`

It starts the pair if needed. `dev-api` applies pending migrations before serving, then the ops sync waits for Swagger from inside the Docker network and regenerates the ui-astro API types.

That Swagger/type sync is implemented in:

```sh
scripts/sync-api-types.sh
```

After changing API routes, response schemas, or Swagger-visible contracts, run:

```sh
make up
```

To refresh or check generated types without recreating the app stack:

```sh
make api-types
make api-types-check
```

Run the API types sync directly from the host:

```sh
bash scripts/sync-api-types.sh
bash scripts/sync-api-types.sh --check
```

Stop the integrated app stack:

```sh
make down
```

Display the development command reference:

```sh
make help
```

Open:

```txt
http://localhost:4321
```

### How the UI Reaches The API

Browser scripts in `ui-astro/src/pages/*.astro` read `PUBLIC_API_URL` and fall back by mode:

| Mode | Default API base | Why |
|------|------------------|-----|
| `astro dev` (`dev-ui`) | `http://localhost:4000` | the API port is published to the host, so the browser reaches it directly |
| `astro build` (`prod-api`) | same origin (`/api/...`) | the API serves the built Astro files, so no CORS is involved |

Override the dev default only when the browser must reach the API on a different host — a phone on your LAN, or an ngrok tunnel. Create `ui-astro/.env`:

```sh
PUBLIC_API_URL=http://192.168.1.42:4000
```

Then add that UI origin to `FRONTEND_URL` in `.env.development`, otherwise the API rejects the browser request with a CORS error. Recreate the UI container after changing it: `docker compose --env-file .env.development up -d dev-ui`.

### Dev Tokens (/register)

`/register` needs a signed, single-use token. In production the WhatsApp dispatcher mints it when an unknown number texts an active tournament slug. For local work, mint one directly:

```sh
make register-token PHONE=799999999 SLUG=torneo-intercolegial
```

That prints a ready-to-open link:

```txt
  phone:      799999999
  tournament: Intercolegial La Paz 2026
  expires:    in 30 minutes
  single use: yes, consumed by POST /api/auth/register

  http://localhost:4321/register?t=eyJhbGciOi...
```

The token is signed with `TOKEN_SIGNING_KEY` from `.env.development` and reuses the API's own `createRegisterToken()`, so it cannot drift from the real flow. It is valid for 30 minutes and is consumed by the first successful `POST /api/auth/register` — mint a fresh one for every test, and expect `410 GONE` when you reuse one (the page redirects to `/expired`).

Seed slugs: `torneo-intercolegial` and `torneo-copa-paz` are active; `torneo-relampago` is not. The helper refuses a phone that is already registered (registration would return `409`) and warns about unknown or inactive slugs.

The same helper is available inside the API repo:

```sh
bun run dev:register-token <phone> <slug>
```

Remove a test registration with:

```sh
docker compose --env-file .env.development exec -T dev-api \
  sqlite3 /peonveloz/api/data/app.db "DELETE FROM users WHERE phone='799999999';"
```

To exercise the real dispatcher instead, pause the worker so the job is not consumed, POST a fake inbound message, then read the token back out of the queue:

```sh
docker compose --env-file .env.development stop dev-worker

curl -s -X POST http://localhost:4000/api/webhook-meta \
  -H 'Content-Type: application/json' \
  -d '{"entry":[{"changes":[{"value":{"messages":[{"from":"799999997","type":"text","text":{"body":"quiero torneo-intercolegial"}}]}}]}]}'

docker compose --env-file .env.development exec -T redis redis-cli LRANGE whatsapp:queue 0 -1 \
  | jq -r '.[0].response.url'

docker compose --env-file .env.development start dev-worker
```

A phone that already has a user gets a `/checkout/:token` link instead of a register link.

## Backend API

`dev-api` expects an Elysia/Bun API at:

```txt
../api
```

Inside the container, SQLite lives at:

```txt
/peonveloz/api/data/app.db
```

The app receives one SQLite source of truth:

```txt
SQLITE_PATH=/peonveloz/api/data/app.db
```

Drizzle derives `DATABASE_URL=file:${SQLITE_PATH}` internally.

### Redis

Redis runs as a separate Compose service using the official `redis:7-alpine` image. The API uses it for login rate limiting, verification tokens, and password reset tokens. The WhatsApp worker uses it as a persistent job queue for outgoing messages.

| Config | Default | Purpose |
|--------|---------|---------|
| `REDIS_URL` | `redis://redis:6379` | Redis connection string inside Compose |
| `REDIS_PORT` | `6379` | Host port for the Redis service |

Inspect Redis from the host:

```sh
redis-cli -h localhost -p 6379 ping
```

Redis is configured with `--save 900 1` (RDB snapshot every 15 minutes if at least one key changed). This ensures WhatsApp queued jobs survive a Redis restart. Rate-limiting and token data remains ephemeral by design since they expire automatically via TTL.

Redis uses `restart: unless-stopped` so Docker restarts it after an unexpected exit. Compose also defines a Redis healthcheck using `redis-cli ping`; the development stack checks once per minute, and the production-like stack checks every 10 seconds. `dev-api` and `prod-api` wait for Redis to become healthy before starting.

When Redis is unreachable the API fails open: rate limiting is skipped, and only a 500ms artificial delay protects against brute-force attempts. Redis recovers automatically within 30 seconds of becoming available again.

The API `/health` endpoint reports dependency status:

```json
{
  "status": "ok",
  "dependencies": {
    "sqlite": "ok",
    "redis": "ok"
  }
}
```

If Redis is down but SQLite is available, `/health` returns `200` with `status: "degraded"`. If SQLite is down, `/health` returns `503` with `status: "unhealthy"`.

### WhatsApp Worker

The worker processes outgoing WhatsApp messages from a Redis-backed job queue. It runs alongside the API but is an independent process — if it crashes, the API keeps serving and queued jobs are preserved in Redis.

In development, the worker starts automatically with `make up` and watches for code changes (`bun --watch`). In production, Docker restarts it automatically (`restart: unless-stopped`).

**Queue keys in Redis** (`redis-cli`):

```sh
redis-cli lrange whatsapp:queue 0 -1    # pending jobs
redis-cli lrange whatsapp:dead 0 -1     # failed after 3 retries
```

**Worker logs**:

```sh
make worker-logs                         # dedicated worker logs
make logs                                # all services including worker
```

Each outgoing message gets up to 3 retry attempts on failure. After 3 failures, the job moves to `whatsapp:dead` for manual inspection. Common failure reasons: invalid access token, Meta API downtime, rate limiting.

**Adding a new automated response** requires changes in two files inside `api/src/lib/whatsapp/`:

| File | What to add |
|------|-------------|
| `dispatcher.ts` | New `if` condition that calls `enqueueJob(from, triggerName)` |
| `whatsapp-worker.ts` | New handler in the `handlers` map that sends the appropriate message |

### Environment Variables

All API runtime configuration is passed through the Docker Compose environment blocks from `ops/.env`.

| Variable | Required | Default | Purpose |
|----------|----------|---------|---------|
| `CSRF_SECRET` | Yes | — | HMAC key for CSRF token signing |
| `TOKEN_SIGNING_KEY` | Yes | — | HMAC-SHA256 key for register/checkout token signing |
| `INTERNAL_API_SECRET` | Yes | — | Shared secret for internal API communication (via X-Internal-Secret header) |
| `REDIS_URL` | No | `redis://redis:6379` | Redis connection for rate limiting and tokens inside Compose |
| `LICHESS_CLIENT_ID` | Yes | — | Lichess OAuth client ID for chess tournament integration |
| `PUSH_NOTIFICATION_API_KEY` | Yes | — | Push notification API key for mobile alerts |
| `FRONTEND_URL` | Yes | — | Allowed CORS origin (comma-separated) |
| `PUBLIC_URL` | Yes | — | Public base URL for links sent via WhatsApp, emails, etc. |
| `NODE_ENV` | No | `development` | Controls cookie Secure flag and session cookie name |
| `WHATSAPP_VERIFY_TOKEN` | No | — | WhatsApp webhook handshake verification token |
| `WHATSAPP_APP_SECRET` | No | — | HMAC-SHA256 secret for webhook signature validation |
| `WHATSAPP_ACCESS_TOKEN` | No | — | Meta WhatsApp Cloud API access token for sending messages |
| `WHATSAPP_PHONE_NUMBER_ID` | No | — | WhatsApp Business phone number ID from Meta dashboard |
| `WHATSAPP_API_URL` | No | `https://graph.facebook.com/v22.0` | Meta Graph API base URL |

In development, `LICHESS_CLIENT_ID` defaults to empty (Lichess integration is skipped but the API does not crash). In production (`docker-compose.prod.yml`), it uses `${LICHESS_CLIENT_ID:?}` and fails fast when the client ID is not set.

In development, `PUSH_NOTIFICATION_API_KEY` defaults to empty (push notifications are not sent but the API does not crash). In production (`docker-compose.prod.yml`), it uses `${PUSH_NOTIFICATION_API_KEY:?}` and fails fast when the key is not set.

Run the integrated app stack:

```sh
make up
```

Open:

```txt
http://localhost:4000
```

Open a shell in the API container:

```sh
make shell-api
```

Open the SQLite database:

```sh
make sqlite-api
```

Apply migrations:

```sh
make db-migrate
```

Seed development fixture data:

```sh
make db-seed
```

Reset the dev SQLite database, then migrate and seed it:

```sh
make db-reset
```

## Production

`prod-api` expects your API repo (including the Astro build) at:

```txt
../api
```

The Dockerfile in `ops/docker/prod-api/Dockerfile` uses a multi-stage build: first build the Astro app from `../ui-astro`, then copy the static bundle into the Elysia server. Elysia serves both the API endpoints and the Astro static files on a single port.

Run production:

```sh
make prod
```

Or directly:

```sh
docker compose -f docker-compose.prod.yml up --build prod-api
```

Open:

```txt
http://localhost:8081
```

The API serves everything from a single origin — no separate frontend container needed.

## Notes

Development SQLite data is stored in the `dev-api-sqlite-data` Docker volume. Production API SQLite data is stored in the `prod-api-sqlite-data` Docker volume. If you run `docker compose down -v`, both local API databases are deleted.

If you previously ran the old Vue `dev-ui`, its volumes are no longer used. Remove them once:

```sh
docker volume rm peonveloz_dev-ui-node-modules peonveloz_dev-ui-bun-cache
```

If Docker Desktop cannot mount your project folders, add those paths to Docker Desktop file sharing settings, or change `UI_PATH` or `API_PATH` in `.env.development`.

To reset all Docker volumes:

```sh
docker compose down -v
```
