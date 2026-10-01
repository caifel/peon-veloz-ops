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
- `dev-api`: runs the Elysia API with Bun, SQLite, and Redis.
- `dev-worker`: procesa la cola de WhatsApp, y **también escribe en SQLite** (guarda el comprobante y lo cuelga del pago). Por eso monta el mismo volumen de datos que `dev-api`.
- `redis`: shared Redis service for tokens and the WhatsApp job queue.

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

### El flujo, de punta a punta

El bot de WhatsApp es la única entrada: **no hay página pública de evento ni
checkout**. El marketing vive en la conversación, y el QR de pago lo manda el
worker al chat.

| # | Qué pasa | Estado |
|---|---|---|
| 1 | Primer mensaje de cualquiera → se registra el contacto y recibe la **lista de eventos** | ✅ |
| 2 | Elige un evento → se crea el pago (`pending`, con el precio congelado) y recibe el **QR** | ✅ |
| 3 | Manda el **comprobante** (imagen) → el worker lo baja, verifica el sha256 y lo guarda | ✅ |
| 4 | Llega la **notificación del banco** (app Android) | ✅ |
| 5 | **Cuadre**: comprobante + notificación → pago `confirmed` + formulario | ❌ |
| 6 | El jugador completa el formulario → `players` + `inscriptions` | ❌ |

Cada paso, con el archivo que lo implementa, está en `HANDOFF.md`.

**Ya no existe la regla de "la última palabra del mensaje = slug".** Ahora el
usuario elige de una lista desplegable y vuelve el `id` de la fila
(`evt-<id>`); cualquier otro texto recibe la lista de nuevo. Lo resuelve
`lib/whatsapp/dispatcher.ts`.

### Alta de eventos (el admin)

El organizador escribe **`crear-evento`** en el chat y el bot le manda un link
con token (60 minutos) a `/new-event`. Ahí llena el formulario y el evento
aparece en la lista de los jugadores.

| Endpoint | Qué hace |
|---|---|
| `GET /api/new-event/:token` | Valida el link y devuelve a nombre de quién se crea |
| `POST /api/new-event` | Crea el evento |

Detalles que importan:

- **El token del POST viaja en el body**, no en la ruta: el log de requests
  registra el path, y un token de autorización no tiene por qué quedar escrito.
- El token se **reclama atómicamente** (SET NX) al empezar y **se devuelve si la
  validación falla**: así un formulario rechazado no quema el link, y un link ya
  usado da `410`.
- La fecha se carga como **hora de Bolivia** (`America/La_Paz`, sin horario de
  verano) y se guarda en UTC. Sin eso, un evento de las 22:00 empezaría a las 18:00.
- El **slug** es lo que el pagador escribe en la glosa de la transferencia, así
  que conviene que sea corto. El formulario lo propone desde el nombre.

### Probar sin WhatsApp

Para no disparar mensajes reales, parar el worker primero (ver la trampa 1 de
`HANDOFF.md`):

```sh
docker compose --env-file .env.development stop dev-worker

curl -s -X POST http://localhost:4000/api/webhook-meta \
  -H 'Content-Type: application/json' \
  -d '{"entry":[{"changes":[{"value":{"messages":[{"from":"799123456","type":"text","text":{"body":"hola"}}]}}]}]}'

# ⚠️ cada línea de LRANGE es un documento JSON: NO le apliques .[]
docker compose --env-file .env.development exec -T redis \
  redis-cli LRANGE whatsapp:queue 0 -1 | jq -r '.messages[] | .body? // .bodyText? // .type'

docker compose --env-file .env.development start dev-worker
```

Y para probar el formulario de alta sin esperar el mensaje del bot:

```sh
docker compose --env-file .env.development exec -T dev-api bun -e \
  "import {createNewEventToken} from '/peonveloz/api/src/lib/whatsapp/tokens.ts'; console.log(createNewEventToken('59173505230'))"
# abrí http://localhost:4321/new-event?t=<lo que imprimió>
```

Teléfonos y slugs del seed: ver el final de `HANDOFF.md`.

### Lichess

`events.isOnline` decide si hace falta cuenta de Lichess. La cuenta vive en
**`players`** (`lichessId`, `lichessUsername`), es opcional y **sin `unique`**:
un evento presencial no la requiere, y dos personas pueden compartir la misma
cuenta (padre e hijo).

**El registro no acepta identidad de Lichess.** La escribe el servidor en el
callback del OAuth, nunca el navegador — eso es lo que impide que alguien se
registre con la cuenta de otro.

`GET /api/auth/lichess?rt=<token>` guarda el teléfono junto al `verifier` PKCE en
Redis; el callback canjea el código, lee la cuenta y la escribe del lado del
servidor. `/api/auth/lichess/status?t=<token>` informa el resultado (`pending`,
`ok`, `not_clean`, `too_few_games`, `oauth_failed`, `user_not_found`) y es lo que
consulta `/verificar-lichess` mientras espera.

**La vista no confirma nada:** cuando el estado es `ok` la cuenta ya está
guardada, así que muestra el overlay y sigue sola al `next`. Los errores se
parten en dos: los reintentables (pantalla de error) y `user_not_found` (va a
`/expired`, porque reintentar el OAuth falla siempre).

> `MIN_RATED_GAMES = 100` en `api/src/lib/lichess-oauth.ts:18` bloquea cuentas
> nuevas de Lichess: bajalo temporalmente para poder probar el OAuth feliz.

### Modelo de evento

`events` guarda lo mínimo: `name`, `slug`, `startTime`, `isOnline`, `onlineUrl`,
`inscriptionPrice`, `marketingText`, `flyerUrl`, `paymentQrUrl` e `isActive`.

- El evento en Lichess lo arma **el organizador** por su cuenta; acá solo se
  guarda el link en `onlineUrl`.
- **`marketingText`** es el texto que el bot manda al chat; el **`flyerUrl`** y el
  **`paymentQrUrl`** son imágenes que el worker **descarga y sube a Meta**, así
  que las URLs no necesitan ser públicas (Meta nunca las visita).
- `inscriptionPrice` está en centavos (0 = gratis) y es el monto que se **congela
  en cada pago**: si el organizador cambia el precio después, lo ya acordado no
  se mueve.

> La vieja columna `pageHtml` **se eliminó**: ya no hay una página por evento.

Criterio de la tabla: **no se agregan columnas hasta que haya código que las
lea.** El detalle campo por campo está en `api/docs/modelo-de-datos.md`.

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

Redis runs as a separate Compose service using the official `redis:7-alpine` image. Hoy se usa para tres cosas:

- la **cola de trabajos** del worker (`whatsapp:queue`, `whatsapp:dead`);
- las **marcas de tokens de un solo uso** (`used_token:<hash>`), que es lo que hace que un link de registro o de alta no se pueda reusar;
- el **`verifier` PKCE** del OAuth de Lichess, mientras dura el handshake.

| Config | Default | Purpose |
|--------|---------|---------|
| `REDIS_URL` | `redis://redis:6379` | Redis connection string inside Compose |
| `REDIS_PORT` | `6379` | Host port for the Redis service |

Inspect Redis from the host:

```sh
redis-cli -h localhost -p 6379 ping
```

Redis is configured with `--save 900 1` (RDB snapshot every 15 minutes if at least one key changed), so queued jobs survive a Redis restart. Los datos de tokens son efímeros a propósito: expiran solos por TTL.

> **Un crash de Redis puede perder hasta 15 minutos.** Hoy eso significa mensajes sin mandar y marcas de un solo uso que se pierden (un link volvería a servir). **Los pagos y los comprobantes no corren ese riesgo: viven en SQLite.** Si algún día algo con plata pasa a vivir solo en Redis, cambiá `appendonly` a `yes`.

Redis uses `restart: unless-stopped` so Docker restarts it after an unexpected exit. Compose also defines a Redis healthcheck using `redis-cli ping`; the development stack checks once per minute, and the production-like stack checks every 10 seconds. `dev-api` and `prod-api` wait for Redis to become healthy before starting.

Cuando Redis no está, la API **no se cae**: la cola de WhatsApp loguea y pierde el job (fail-open), y las marcas de un solo uso no se pueden escribir, así que `markTokenAsUsed` devuelve `false` y el alta de eventos rechaza la creación — es preferible a dejar reusar un link. Redis se recupera solo cuando vuelve.

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

Un job lleva una **lista de mensajes en orden** (`messages: OutgoingMessage[]`), y el worker manda uno por uno. Si el tercero falla, el reintento arranca **desde el que falló**, no desde el principio: nadie recibe el flyer dos veces.

Un job también puede llevar un **comprobante entrante** (`receipt`). En ese caso el worker lo primero que hace es bajarlo de Meta, verificar el sha256 y guardarlo: si eso falla, el job vuelve a la cola y los mensajes **no salen**, porque no se le puede contestar "recibí tu comprobante" a algo que no tenemos.

**Para agregar una respuesta nueva** alcanza con un archivo: el dispatcher arma el array de mensajes y llama a `enqueueJob(from, trigger, messages)`. **No hay un mapa de handlers**: el worker solo manda lo que dice el job. Para un tipo de mensaje nuevo (por ejemplo una encuesta) hay que agregar la variante a `OutgoingMessage` en `queue.ts` y su rama en `sendMessage` (`whatsapp-worker.ts`).

### Environment Variables

All API runtime configuration is passed through the Docker Compose environment blocks from `ops/.env`.

| Variable | Required | Default | Purpose |
|----------|----------|---------|---------|
| `SQLITE_PATH` | Yes | — | Ruta de la base. **La necesitan el api y el worker**, con el mismo valor |
| `CSRF_SECRET` | Yes | — | Se exige en `lib/config.ts`, pero **el CSRF se eliminó**: hoy no firma nada |
| `TOKEN_SIGNING_KEY` | Yes | — | HMAC-SHA256 de los tokens (registro, alta de evento, link de Lichess) |
| `REDIS_URL` | No | `redis://redis:6379` | Redis para la cola y las marcas de tokens |
| `LICHESS_CLIENT_ID` | Yes | — | Lichess OAuth client ID for chess tournament integration |
| `PUSH_NOTIFICATION_API_KEY` | Yes | — | Clave del `X-API-Key` que manda la app Android (`bridger`) |
| `FRONTEND_URL` | Yes | — | Allowed CORS origin (comma-separated) |
| `PUBLIC_URL` | Yes | — | Public base URL for links sent via WhatsApp, emails, etc. |
| `NODE_ENV` | No | `development` | `development` \| `test` \| `production` |
| `RECEIPTS_DIR` | No | `data/receipts` | Dónde viven los comprobantes. Relativo al cwd; cae dentro del volumen de datos |
| `WHATSAPP_VERIFY_TOKEN` | No | — | WhatsApp webhook handshake verification token |
| `WHATSAPP_APP_SECRET` | No | — | HMAC-SHA256 secret for webhook signature validation |
| `WHATSAPP_ACCESS_TOKEN` | No | — | Meta WhatsApp Cloud API access token for sending messages |
| `WHATSAPP_PHONE_NUMBER_ID` | No | — | WhatsApp Business phone number ID from Meta dashboard |
| `WHATSAPP_PUBLIC_PHONE` | No | — | El número del bot como aparece en un link `wa.me` (no es el ID de Meta) |
| `WHATSAPP_API_URL` | No | `https://graph.facebook.com/v22.0` | Meta Graph API base URL |

`SQLITE_PATH` y el volumen de datos son **lo que hace que el api y el worker vean
la misma base**. Si agregás un import que toque SQLite en un proceso nuevo,
acordate de las dos cosas (ver la trampa 4 de `HANDOFF.md`).

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

Development SQLite data is stored in the `dev-api-sqlite-data` Docker volume — **the api and the worker both mount it**, because the worker writes payments too. Production API SQLite data is stored in the `prod-api-sqlite-data` Docker volume (also shared with `prod-worker`). If you run `docker compose down -v`, both local API databases are deleted.

Los **comprobantes** (`data/receipts/`) viven dentro de ese mismo volumen, con el sha256 como nombre de archivo. No se sirven por HTTP: son la prueba de un pago, no un asset público.

> ⚠️ **`make up` corre `db:seed` siempre, y el seed borra y recrea los datos.**
> Si querés levantar conservando lo que tenías:
> `docker compose --env-file .env.development up -d`.

If you previously ran the old Vue `dev-ui`, its volumes are no longer used. Remove them once:

```sh
docker volume rm peonveloz_dev-ui-node-modules peonveloz_dev-ui-bun-cache
```

If Docker Desktop cannot mount your project folders, add those paths to Docker Desktop file sharing settings, or change `UI_PATH` or `API_PATH` in `.env.development`.

To reset all Docker volumes:

```sh
docker compose down -v
```
