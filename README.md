# Docker Web Development Environment

This folder defines the Docker containers for your web development workflow. Docker through this `ops` project is the only supported local development path.

Your project source lives outside this folder:

```txt
../ui
../api
```

This Docker setup lives here:

```txt
../ops
```

## Containers

The development Compose stack has three containers:

- `dev-ui`: runs the `peonveloz` Vue app in development mode via Vite.
- `dev-api`: runs the Elysia API with Bun, SQLite, and Redis (rate limiting).
- `redis`: shared Redis service for API rate limiting, tokens, and local test runs.

Production local testing lives in `docker-compose.prod.yml`:

- `prod-api`: builds and runs the Elysia API in production mode, serving Vue static files.
- `redis`: shared Redis service for the production API container.

All custom images use Debian Bookworm slim bases through `oven/bun:1-debian`.

## How The Containers Connect

`dev-ui` mounts the UI app:

```txt
../ui -> /peonveloz/ui
```

`dev-api` mounts your API project:

```txt
../api -> /peonveloz/api
```

`prod-api` uses the API folder as its Docker build context from `docker-compose.prod.yml`. The Vue bundle is built as part of the API image (multi-stage build).

The result:

- edit code directly on your host machine
- run API tests from the host or inside `dev-api`
- run the integrated dev stack with `dev-ui` and `dev-api` together
- regenerate ui API types from the fresh `dev-api` Swagger schema during startup
- build/run the production image with `prod-api` (API + Vue static files)

Runtime configuration lives in this folder:

- `.env.development` is the local source of truth for Docker dev runs.
- `.env.production` is the local source of truth for production-like local runs.
- `.env.development.example` and `.env.production.example` document the required variables.
- `ui/.env.local` and `api/.env` are intentionally not used by the supported dev workflow.

## Quick Start

Copy the example environment files and fill the local Docker values:

```sh
cp .env.development.example .env.development
cp .env.production.example .env.production
```

Clone your project repositories:

```sh
cd ..
git clone git@github.com:YOUR_USER/peonveloz.git ui
git clone git@github.com:YOUR_USER/peonveloz-api.git api
```

Start the integrated app stack:

```sh
make up
```

This starts/recreates:

- `dev-api`
- `dev-ui`

It starts the pair if needed. `dev-api` applies pending migrations before serving, then the ops sync waits for Swagger from inside the Docker network and regenerates the ui API types.

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
http://localhost:5173
```

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

Redis runs as a separate Compose service using the official `redis:7-alpine` image. The API uses it for login rate limiting, verification tokens, and password reset tokens.

| Config | Default | Purpose |
|--------|---------|---------|
| `REDIS_URL` | `redis://redis:6379` | Redis connection string inside Compose |
| `REDIS_PORT` | `6379` | Host port for the Redis service |

Inspect Redis from the host:

```sh
redis-cli -h localhost -p 6379 ping
```

Redis is started with flags that disable persistence (`--save "" --appendonly no`) since the current data is ephemeral and expires automatically. No cleanup jobs needed.

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

### Environment Variables

All API runtime configuration is passed through the Docker Compose environment blocks from `ops/.env`.

| Variable | Required | Default | Purpose |
|----------|----------|---------|---------|
| `CSRF_SECRET` | Yes | — | HMAC key for CSRF token signing |
| `INTERNAL_API_SECRET` | Yes | — | Shared secret for internal API communication (via X-Internal-Secret header) |
| `REDIS_URL` | No | `redis://redis:6379` | Redis connection for rate limiting and tokens inside Compose |
| `LICHESS_CLIENT_ID` | Yes | — | Lichess OAuth client ID for chess tournament integration |
| `PUSH_NOTIFICATION_API_KEY` | Yes | — | Push notification API key for mobile alerts |
| `FRONTEND_URL` | Yes | — | Allowed CORS origin (comma-separated) |
| `NODE_ENV` | No | `development` | Controls cookie Secure flag and session cookie name |

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

`prod-api` expects your API repo (including the Vue build) at:

```txt
../api
```

The Dockerfile in `../api` should use a multi-stage build: first build the Vue app from `../ui`, then copy the static bundle into the Elysia server. Elysia serves both the API endpoints and the Vue static files on a single port.

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

If Docker Desktop cannot mount your project folders, add those paths to Docker Desktop file sharing settings, or change `UI_PATH` or `API_PATH` in `.env.development`.

To reset all Docker volumes:

```sh
docker compose down -v
```
