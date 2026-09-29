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

### Generar URLs (register, checkout, verify)

Cada paso del flujo necesita su propio token firmado, y en producción los mintea el dispatcher de WhatsApp según el caso. Para trabajar local no hay que armar ninguno a mano: **`generate-url` usa la misma lógica del dispatcher y decide solo qué link corresponde.**

```sh
make generate-url PHONE=799999999 SLUG=torneo-intercolegial
```

Imprime qué camino tomó y por qué, más el link listo para abrir:

```txt
  phone:      77777777
  tournament: Arena Online Peón Veloz
  expires:    in 30 minutes

  user:       ya existe (Admin) -> verificar-lichess
  single use: no

  Torneo online sin cuenta de Lichess: va directo a vincularla,
  y el `next` lo devuelve al checkout cuando termine.

  http://localhost:4321/verificar-lichess?t=eyJhbGciOi...&next=%2Fcheckout%3Ft%3D...
```

Los tres caminos, iguales a los de `dispatcher.ts`:

| Teléfono + torneo | Link |
|---|---|
| Teléfono desconocido | `/register?t=<registerToken>` |
| Ya existe, presencial **o** con cuenta de Lichess | `/checkout?t=<checkoutToken>` |
| Ya existe, online y **sin** cuenta | `/verificar-lichess?t=<lichessLink>&next=<checkout>` |

Los tokens salen de las mismas funciones que usa el dispatcher (`createRegisterToken`, `createCheckoutToken`, `createLichessLinkToken`), firmados con `TOKEN_SIGNING_KEY`, así que no pueden divergir del flujo real. **El de registro es el único de un solo uso**: lo consume `POST /api/auth/register`, y si lo reusás da `410 GONE` (la página va a `/expired`).

También avisa si el slug no existe o si el torneo está inactivo, aclarando que en ese caso el dispatcher real ignoraría el mensaje.

Seed slugs: `torneo-intercolegial` y `torneo-copa-paz` son activos, `torneo-relampago` no, y `torneo-online-arena` es el único **online**.

Para probar los dos caminos de un usuario que ya existe hay teléfonos en el seed: `77777777` (Admin, **sin** cuenta → manda a verificar) y `780000000` (Carlos, **con** cuenta → va directo a pagar).

Para probar los dos caminos de un usuario que ya existe hay teléfonos en el seed: `77777777` (Admin, **sin** cuenta de Lichess → manda a verificar) y `780000000` (Carlos, **con** cuenta → va directo a pagar).

### Modalidad y cuenta de Lichess

`tournaments.isOnline` decide si hace falta cuenta de Lichess. En `users`, `lichessId` y `lichessUsername` son **opcionales y sin `unique`**: un torneo presencial no requiere Lichess, y dos personas pueden compartir la misma cuenta (padre e hijo).

**El registro no acepta identidad de Lichess.** `POST /api/auth/register` solo crea la persona; no tiene campos `lichessId`/`lichessUsername`. La cuenta se vincula aparte, vía OAuth, en la vista dedicada `/verificar-lichess`. Eso es lo que impide que alguien se registre con la cuenta de otro: la identidad la escribe el servidor en el callback, no el navegador.

| Paso | Dónde |
|---|---|
| 1. Crear la persona | `/register?t=<registerToken>` → `POST /api/auth/register` |
| 2. Vincular Lichess (**solo online**) | `/verificar-lichess?t=<lichessLink>&next=<checkout>` |
| 3. Inscribirse y pagar | `/checkout?t=<checkoutToken>` (el pago todavía no existe server-side) |

**El registro siempre termina en el checkout**, porque inscribirse requiere pagar. Como `POST /api/auth/register` consume el token de registro, la misma respuesta emite un `checkoutToken` (de 30 minutos, no 5: el camino online pasa por el OAuth antes de llegar a pagar).

- Torneo **presencial** → `lichessLink: null` → la página va directo a `/checkout?t=<checkoutToken>`.
- Torneo **online** → `lichessLink` presente → va a `/verificar-lichess` con `next` apuntando al checkout, así después de vincular la cuenta vuelve solo a pagar.

### Quién entra por dónde

El **dispatcher** (el botón de WhatsApp) y la **página de registro** resuelven lo mismo con el mismo criterio, así que las dos entradas son simétricas:

| Situación | A dónde manda el botón |
|---|---|
| Teléfono desconocido | `/register?t=<registerToken>` |
| Ya existe, torneo presencial | `/checkout?t=<checkoutToken>` |
| Ya existe, online **con** cuenta vinculada | `/checkout?t=<checkoutToken>` |
| Ya existe, online **sin** cuenta | `/verificar-lichess?t=<lichessLink>&next=<checkout>` — directo a verificar, y de ahí al checkout |

El botón dice lo que va a pasar: "Registro de usuario", "Realizar pago" o "Verificar cuenta" según la fila.

El checkout **igual exige** la cuenta para torneos online. No es redundante: es la red de seguridad para quien entra con un link viejo o pierde el `next` en el camino.

Cómo viaja la identidad en el paso 2: `GET /api/auth/lichess?rt=<token>` guarda el teléfono junto al `verifier` PKCE en Redis; el callback canjea el código, lee la cuenta de Lichess y **escribe `users.lichessId` del lado del servidor**. El navegador nunca ve ni envía la identidad. `/api/auth/lichess/status?t=<token>` informa el resultado (`pending`, `ok`, `not_clean`, `too_few_games`, `oauth_failed`, `user_not_found`) y es lo que consulta la vista mientras espera.

**La vista no confirma nada:** cuando el estado es `ok` la cuenta ya está guardada (la escritura la hizo el callback), así que muestra el overlay de carga y sigue sola a `next`. No hay pantalla de "vinculamos la cuenta" ni botón de continuar: era un toque sin ninguna decisión, y el checkout igual muestra con qué cuenta quedó.

Los errores se parten en dos, según si reintentar puede servir:

| Resultado | Qué hace la vista |
|---|---|
| `oauth_failed`, `too_few_games`, `not_clean` | Pantalla de error con el motivo y la barra de acción (con el texto ajustado: "Reintentar" o "Probar con otra cuenta") |
| `user_not_found` | Va a `/expired`, porque reintentar el OAuth falla siempre: el problema es que no existe el registro, y la salida es pedir un link nuevo |

Sin `next` en la URL la vista también corta a `/expired`, y lo hace **al inicio**: no tiene sentido que el usuario complete el OAuth para que después no sepamos a dónde mandarlo.

El checkout además **exige** la cuenta para torneos online, y eso cubre a los usuarios que ya existen: `GET /api/checkout/:token` devuelve `isOnline`, `hasLichess` y, si falta, un `lichessLink` nuevo para ir a verificar y volver. Es el caso de alguien que se registró para un torneo presencial y después quiere uno virtual — ese camino entra directo por el checkout, sin pasar por el registro.

### Modelo de torneo

`tournaments` guarda lo mínimo (9 campos): `name`, `slug`, `startTime`, `isOnline`, `onlineUrl`, `inscriptionPrice`, `pageHtml` y `isActive`. El torneo en Lichess lo arma **el organizador** por su cuenta y acá solo se guarda el link en `onlineUrl`; todo el resto del evento (sede, ritmo, variante, premios, cupo) vive en `pageHtml`, que diseña el organizador.

`inscriptionPrice` es el `amount` de la inscripción (centavos, 0 = gratis).

**`pageHtml` todavía NO se renderiza.** Falta decidir cómo se sanitiza: inyectar HTML del organizador en el origen propio es un vector de stored XSS (accede a cookies, sesión y a la API same-origin). Y como todavía no hay login, no hay forma de restringir quién crea torneos.

Criterio de la tabla: **no se agregan columnas hasta que haya código que las lea**. Por eso se sacaron `registrationDeadline`, `maxParticipants`, `rounds`, `systemOfPlay`, `clockTime` y compañía — se usaban solo en `routes/tournaments.ts`, que está desmontado y escrito contra un esquema anterior. Cuando exista el código que las aplique, se agregan de vuelta.

Para probar ambos caminos:

```sh
make generate-url PHONE=799999999 SLUG=torneo-intercolegial   # nuevo + presencial: register -> /checkout
make generate-url PHONE=799999998 SLUG=torneo-online-arena    # nuevo + online: register -> /verificar-lichess -> /checkout
```

El paso 2 necesita una cuenta real de Lichess: es lo único del flujo que no se puede verificar con `curl`.

El mismo helper está disponible dentro del repo de la API:

```sh
bun run dev:generate-url <phone> <slug>
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
