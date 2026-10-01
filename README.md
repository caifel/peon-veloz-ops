# Peón Veloz — el stack de desarrollo

Este directorio define los contenedores de Peón Veloz. **Levantar el proyecto a
mano no está soportado**: el camino es Docker a través de este `ops`.

El código vive afuera de este directorio:

```txt
../api        la API (Elysia + Bun + SQLite + Redis)
../ui-astro   la UI (Astro)
```

| Querés… | Leé |
|---|---|
| El estado, los pendientes, el norte y las trampas | `HANDOFF.md` |
| Cómo funciona el flujo y cómo levantar el stack | **este archivo** |
| Las tablas, campo por campo | `../api/docs/modelo-de-datos.md` |

---

## Los contenedores

### Desarrollo (`docker-compose.yml`) — cuatro

| Contenedor | Qué hace |
|---|---|
| `dev-ui` | Corre la UI con `astro dev` (escucha cambios en caliente) |
| `dev-api` | Corre la API con `bun run --watch` |
| `dev-worker` | Procesa la cola de WhatsApp **y escribe en SQLite** (guarda el comprobante y lo cuelga del pago). Por eso monta el mismo volumen de datos que `dev-api` |
| `redis` | Cola de trabajos y marcas de tokens |

### Producción local (`docker-compose.prod.yml`) — tres

| Contenedor | Qué hace |
|---|---|
| `prod-api` | Corre la API en modo producción y **sirve la UI ya compilada** en el mismo origen |
| `prod-worker` | Procesa la cola de WhatsApp (reusa la imagen de `prod-api`) |
| `redis` | Igual que en dev |

Las imágenes propias parten de Debian Bookworm slim: la API y el worker usan
`oven/bun:1-debian`, y la UI usa `node:22-slim` para que el dev server y el build
de producción corran sobre el mismo major de Node.

---

## Cómo se conectan

`dev-ui` monta la UI y `dev-api` monta la API:

```txt
../ui-astro -> /peonveloz/ui-astro
../api      -> /peonveloz/api
```

`prod-api` usa `../api` como contexto de build, y compila la UI **dentro** de esa
imagen (build multi-stage). El resultado:

- editás el código en tu máquina y el contenedor lo ve al instante
- podés correr los tests desde el host o adentro de `dev-api`
- los tipos de la UI se regeneran solos desde el Swagger de la API
- con `prod-api` tenés la app entera (API + estáticos) en un solo origen

### Dónde vive la configuración

| Archivo | Para qué |
|---|---|
| `.env.development` | La fuente de verdad del stack de dev |
| `.env.production` | La fuente de verdad de la corrida tipo producción |
| `.env.development.example`, `.env.production.example` | Documentan las variables |
| `api/.env` | **No se usa**: la API lee de `ops/.env.development` |
| `ui-astro/.env` | Opcional, solo para overrides de la UI como `PUBLIC_API_URL` |

---

## Empezar

> ### ⚠️ `make up` **reemplaza los datos locales**
>
> Corre `db:seed` **siempre**, y el seed borra y recrea contactos, jugadores y
> eventos. Para levantar conservando lo que tenías:
>
> ```sh
> docker compose --env-file .env.development up -d
> ```

Copiá los archivos de entorno y completá los valores locales:

```sh
cp .env.development.example .env.development
cp .env.production.example .env.production
```

Cloná los repos:

```sh
cd ..
git clone git@github.com:caifel/peon-veloz-ui-astro.git ui-astro
git clone git@github.com:caifel/peon-veloz-api.git api
```

Levantá el stack:

```sh
make up
```

Eso hace tres cosas, en orden:

1. `bun install` en el api, y **si la base no existe**, le crea el esquema
   (`db:push`). No aplica migraciones en cada arranque: la base ya creada queda
   como está.
2. `db:seed` — **siempre**, así que reemplaza los datos (ver el aviso de arriba).
3. Sincroniza los tipos de la UI desde el Swagger de la API.

Después abrí:

```txt
http://localhost:4321     la UI
http://localhost:4000     la API
http://localhost:4000/swagger
```

> **El puerto 4321 tiene que estar libre.** Si tenés un `astro dev` corriendo en el
> host, parálo primero (`cd ../ui-astro && npx astro dev stop`), si no el contenedor
> no puede tomarlo.

Para ver todos los comandos con su descripción: `make help`. Para parar el stack
sin borrar los datos: `make down`.

### Los tipos de la UI

El contrato de la API se publica en Swagger y de ahí se **generan** los tipos de
`ui-astro/src/api/generated/schema.ts`. El script es
`scripts/sync-api-types.sh`, y lee el schema desde adentro de la red de Docker
(`http://dev-api:4000/swagger/json`).

| Comando | Qué hace |
|---|---|
| `make api-types` | Regenera los tipos |
| `make api-types-check` | Falla si quedaron desactualizados |

Cada vez que cambiás una ruta o un esquema de respuesta, corré `make up` (o
`make api-types`) y commiteá el archivo generado. **`api-types-check` no es un
typecheck**: solo verifica que los tipos generados estén al día.

---

## El flujo del producto

El bot de WhatsApp es la única entrada: **no hay página pública de evento ni
checkout**. El marketing vive en la conversación, y el QR de pago lo manda el
worker al chat.

Esta tabla es el **estado** de cada paso. La experiencia que buscamos y qué
significa que funcione están en *El norte* de `HANDOFF.md`.

| # | Qué pasa | Estado |
|---|---|---|
| 1 | Primer mensaje de cualquiera → se registra el contacto y recibe la **lista de eventos** | ✅ |
| 2 | Elige un evento → se crea el pago (`pending`, con el precio congelado) y recibe el **QR** | ✅ |
| 3 | Manda el **comprobante** (imagen) → el worker lo baja, verifica el sha256 y lo guarda | ✅ |
| 4 | Llega la **notificación del banco** (app Android) | ✅ |
| 5 | **Confirmación**: comprobante + notificación → pago `confirmed` + formulario | ❌ *(la hace el admin a mano primero, ver P0 del HANDOFF)* |
| 6 | El jugador completa el formulario → `players` + `inscriptions` | ❌ |

> ⚠️ **El flujo no cierra todavía.** Nadie confirma el pago, y el bot contesta que
> va a avisar cuando esté confirmado — ese aviso no existe. No lo pongas en manos
> de jugadores reales. Detalle en `HANDOFF.md`.

Cada paso, con el archivo que lo implementa, está en `HANDOFF.md`.

### La entrada

**Ya no existe la regla de "la última palabra del mensaje = slug".** El usuario
elige de una lista desplegable y vuelve el `id` de la fila (`evt-<id>`); cualquier
otro texto recibe la lista de nuevo. Los límites de WhatsApp mandan: máximo 10
filas, título de 24 caracteres. Lo resuelve `lib/whatsapp/dispatcher.ts`.

### Alta de eventos (el admin)

El organizador escribe **`crear-evento`** en el chat, el bot le manda un link con
token (60 minutos) a `/new-event`, y ahí llena el formulario. El evento aparece en
la lista de los jugadores.

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
- El **slug** es lo que el pagador escribe en la glosa de la transferencia, así que
  conviene que sea corto. El formulario lo propone desde el nombre.

### Modelo de evento

`events` guarda lo mínimo: `name`, `slug`, `startTime`, `isOnline`, `onlineUrl`,
`inscriptionPrice`, `marketingText`, `flyerUrl`, `paymentQrUrl` e `isActive`.

- El evento en Lichess lo arma **el organizador** por su cuenta; acá solo se guarda
  el link en `onlineUrl`.
- **`marketingText`** es el texto que el bot manda al chat; el **`flyerUrl`** y el
  **`paymentQrUrl`** son imágenes que el worker **descarga y sube a Meta**, así que
  las URLs no necesitan ser públicas (Meta nunca las visita).
- `inscriptionPrice` está en centavos (0 = gratis) y es el monto que se **congela en
  cada pago**: si el organizador cambia el precio después, lo ya acordado no se mueve.

> La vieja columna `pageHtml` **se eliminó**: ya no hay una página por evento.

Criterio de la tabla: **no se agregan columnas hasta que haya código que las lea.**
El detalle campo por campo está en `../api/docs/modelo-de-datos.md`.

### Lichess

`events.isOnline` decide si hace falta cuenta de Lichess. La cuenta vive en
**`players`** (`lichessId`, `lichessUsername`), es opcional y **sin `unique`**: un
evento presencial no la requiere, y dos personas pueden compartir la misma cuenta
(padre e hijo).

**El registro no acepta identidad de Lichess.** La escribe el servidor en el
callback del OAuth, nunca el navegador — eso es lo que impide que alguien se
registre con la cuenta de otro.

`GET /api/auth/lichess?rt=<token>` guarda el teléfono junto al `verifier` PKCE en
Redis; el callback canjea el código, lee la cuenta y la escribe del lado del
servidor. `/api/auth/lichess/status?t=<token>` informa el resultado (`pending`,
`ok`, `not_clean`, `too_few_games`, `oauth_failed`, `user_not_found`) y es lo que
consulta `/verificar-lichess` mientras espera.

**La vista no confirma nada:** cuando el estado es `ok` la cuenta ya está guardada,
así que muestra el overlay y sigue sola al `next`. Los errores se parten en dos: los
reintentables (pantalla de error) y `user_not_found` (va a `/expired`, porque
reintentar el OAuth falla siempre).

> `MIN_RATED_GAMES = 100` en `api/src/lib/lichess-oauth.ts:18` bloquea cuentas
> nuevas de Lichess: bajalo temporalmente para poder probar el OAuth feliz.

### Probar sin WhatsApp

⚠️ **El worker manda WhatsApp de verdad.** Si está arriba y posteás al webhook,
salen mensajes reales. Para inspeccionar sin enviar, parálo primero:

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

Y para abrir el formulario de alta sin esperar el mensaje del bot:

```sh
docker compose --env-file .env.development exec -T dev-api bun -e \
  "import {createNewEventToken} from '/peonveloz/api/src/lib/whatsapp/tokens.ts'; console.log(createNewEventToken('59173505230'))"
# abrí http://localhost:4321/new-event?t=<lo que imprimió>
```

Para correr un worker de un solo uso con otro `WHATSAPP_API_URL` (por ejemplo
contra un servidor de prueba), **no uses `exec` en un contenedor parado**: usá
`docker compose run --rm -T -e VAR=… dev-worker sh -c "…"`.

Los contactos de prueba se acumulan (cada número nuevo crea un `users`). Se borran
con su jugador y sus pagos, que caen en cascada:

```sh
docker compose --env-file .env.development exec -T dev-api \
  sqlite3 /peonveloz/api/data/app.db "DELETE FROM users WHERE phone='799123456';"
```

Teléfonos y eventos del seed: al final de `HANDOFF.md`.

---

## Cómo la UI llega a la API

Los scripts del navegador en `ui-astro/src/pages/*.astro` leen `PUBLIC_API_URL` y
si no está, eligen según el modo:

| Modo | Base de la API | Por qué |
|---|---|---|
| `astro dev` (`dev-ui`) | `http://localhost:4000` | El puerto de la API está publicado en el host, así que el navegador la alcanza directo |
| `astro build` (`prod-api`) | El mismo origen (`/api/...`) | La API sirve los estáticos, así que no hay CORS |

Overrideá el default de dev solo si el navegador tiene que llegar a la API en otro
host — un teléfono en tu red, o un túnel de ngrok. Creá `ui-astro/.env`:

```sh
PUBLIC_API_URL=http://192.168.1.42:4000
```

Y agregá ese origen de la UI a `FRONTEND_URL` en `.env.development`, si no la API
rechaza el pedido con un error de CORS. Después recreá el contenedor de la UI:
`docker compose --env-file .env.development up -d dev-ui`.

---

## El backend

### SQLite

Adentro del contenedor la base vive en:

```txt
/peonveloz/api/data/app.db
```

Y la API recibe una sola fuente de verdad:

```txt
SQLITE_PATH=/peonveloz/api/data/app.db
```

Drizzle deriva `DATABASE_URL=file:${SQLITE_PATH}` por su cuenta.

**El api y el worker abren el mismo archivo**, así que los dos necesitan
`SQLITE_PATH` con el mismo valor y el volumen de datos montado (ver *Variables de
entorno* y la trampa 4 de `HANDOFF.md`). La base corre en modo WAL, que permite
leer mientras otro proceso escribe.

### Redis

Redis es un servicio aparte, con la imagen oficial `redis:7-alpine`. Hoy se usa
para tres cosas:

- la **cola de trabajos** del worker (`whatsapp:queue`, `whatsapp:dead`);
- las **marcas de tokens de un solo uso** (`used_token:<hash>`), que es lo que hace
  que un link de registro o de alta no se pueda reusar;
- el **`verifier` PKCE** del OAuth de Lichess, mientras dura el handshake.

| Variable | Default | Para qué |
|---|---|---|
| `REDIS_URL` | `redis://redis:6379` | Conexión desde adentro de Compose |
| `REDIS_PORT` | `6379` | Puerto en el host |

Para mirarlo desde el host: `redis-cli -h localhost -p 6379 ping`.

Está configurado con `--save 900 1` (snapshot cada 15 minutos si cambió al menos
una clave), así que los jobs encolados sobreviven a un restart. Los datos de tokens
son efímeros a propósito: expiran solos por TTL.

> **Un crash de Redis puede perder hasta 15 minutos.** Hoy eso significa mensajes
> sin mandar y marcas de un solo uso que se pierden (un link volvería a servir).
> **Los pagos y los comprobantes no corren ese riesgo: viven en SQLite.** Si algún
> día algo con plata pasa a vivir solo en Redis, cambiá `appendonly` a `yes`.

Corre con `restart: unless-stopped`, y Compose le define un healthcheck con
`redis-cli ping`: el stack de dev lo chequea una vez por minuto, el de producción
cada 10 segundos. `dev-api` y `prod-api` esperan a que esté sano para arrancar.

Cuando Redis no está, la API **no se cae**: la cola de WhatsApp loguea y pierde el
job (fail-open), y las marcas de un solo uso no se pueden escribir, así que
`markTokenAsUsed` devuelve `false` y el alta de eventos rechaza la creación — es
preferible a dejar reusar un link. Redis se recupera solo cuando vuelve.

`/health` informa el estado de las dependencias:

```json
{ "status": "ok", "dependencies": { "sqlite": "ok", "redis": "ok" } }
```

Si Redis está caído pero SQLite anda, devuelve `200` con `status: "degraded"`. Si
SQLite está caído, devuelve `503` con `status: "unhealthy"`.

### El worker de WhatsApp

Procesa los mensajes de una cola en Redis. Corre al lado de la API pero es un
proceso independiente: si se cae, la API sigue sirviendo y los jobs quedan en Redis.
En dev arranca con `make up` y mira los cambios (`bun --watch`); en producción
Docker lo reinicia (`restart: unless-stopped`).

**Claves de la cola:**

```sh
redis-cli lrange whatsapp:queue 0 -1    # jobs pendientes
redis-cli lrange whatsapp:dead 0 -1     # muertos después de 3 intentos
```

**Logs:** `make worker-logs` (solo el worker) o `make logs` (todo).

Cada job tiene hasta **3 intentos**. Un job lleva una **lista de mensajes en orden**
(`messages: OutgoingMessage[]`) y el worker manda uno por uno; si el tercero falla,
el reintento arranca **desde el que falló**, no desde el principio: nadie recibe el
flyer dos veces. Después de 3 fallas el job va a `whatsapp:dead` para mirarlo a mano.

Un job también puede llevar un **comprobante entrante** (`receipt`). En ese caso lo
primero que hace el worker es bajarlo de Meta, verificar el sha256 y guardarlo: si
eso falla, el job vuelve a la cola y los mensajes **no salen**, porque no se le puede
contestar "recibí tu comprobante" a algo que no tenemos.

**Para agregar una respuesta nueva** alcanza con un archivo: el dispatcher arma el
array de mensajes y llama a `enqueueJob(from, trigger, messages)`. **No hay un mapa
de handlers**: el worker solo manda lo que dice el job. Para un tipo de mensaje nuevo
(por ejemplo una encuesta) hay que agregar la variante a `OutgoingMessage` en
`queue.ts` y su rama en `sendMessage` (`whatsapp-worker.ts`).

---

## Variables de entorno

Toda la configuración de la API entra por los bloques `environment` de los compose,
que leen de `ops/.env.development` (o `.env.production`).

**«Obligatoria» quiere decir que el compose no arranca sin ella** (`${VAR:?}`).
Las que no lo son, pueden quedar vacías.

| Variable | ¿Obligatoria? | Para qué |
|---|---|---|
| `SQLITE_PATH` | sí | La ruta de la base. **El api y el worker, con el mismo valor** |
| `FRONTEND_URL` | sí | Orígenes permitidos por CORS (separados por coma) |
| `CSRF_SECRET` | sí | Se exige en `lib/config.ts`, pero **el CSRF se eliminó**: hoy no firma nada |
| `TOKEN_SIGNING_KEY` | sí | HMAC-SHA256 de los tokens (registro, alta de evento, link de Lichess) |
| `REDIS_URL` | sí | Redis para la cola y las marcas de tokens |
| `LICHESS_CLIENT_ID` | sí | OAuth de Lichess |
| `PUSH_NOTIFICATION_API_KEY` | sí | La clave del `X-API-Key` que manda la app Android (`bridger`) |
| `PUBLIC_URL` | en dev tiene default | URL pública base para los links que salen por WhatsApp |
| `NODE_ENV`, `HOST`, `PORT` | las fija el compose | — |
| `RECEIPTS_DIR` | no | Dónde viven los comprobantes. Default `data/receipts`, relativo al cwd (cae dentro del volumen) |
| `WHATSAPP_VERIFY_TOKEN` | no | Verificación del handshake del webhook |
| `WHATSAPP_APP_SECRET` | no | HMAC-SHA256 para validar la firma del webhook (**hoy es opcional**, ver P1 del HANDOFF) |
| `WHATSAPP_ACCESS_TOKEN` | no | Token de Meta para mandar mensajes |
| `WHATSAPP_PHONE_NUMBER_ID` | no | El ID del número en el panel de Meta |
| `WHATSAPP_PUBLIC_PHONE` | no | El número del bot como aparece en un link `wa.me` (no es el ID de Meta) |
| `WHATSAPP_API_URL` | no | Base de la Graph API. Default `https://graph.facebook.com/v22.0` |

Sin las `WHATSAPP_*` la API arranca igual, pero el bot no manda nada.

`SQLITE_PATH` y el volumen de datos son **lo que hace que el api y el worker vean la
misma base**. Si agregás un import que toque SQLite en un proceso nuevo, acordate de
las dos cosas.

---

## Los comandos

`make help` los lista todos con su descripción. Los que más se usan:

| Comando | Qué hace |
|---|---|
| `make up` | Levanta el stack (⚠️ **reemplaza los datos**) |
| `make down` | Para los contenedores, conserva los volúmenes |
| `make logs` / `make logs-api` / `make worker-logs` | Logs |
| `make status` | Estado de los contenedores |
| `make api-test` | La suite completa, adentro de `dev-api` |
| `make api-types` / `make api-types-check` | Genera / verifica los tipos de la UI |
| `make db-seed` | Siembra los fixtures (reemplaza datos) |
| `make db-migrate` | Aplica las migraciones |
| `make db-reset` | Borra la base, migra y siembra |
| `make db-rebuild` | Recrea la migración desde `schema.ts`, borra la base, migra y siembra |
| `make db-migration-refresh` | Solo recrea la migración desde `schema.ts` |
| `make shell-api` | Una shell en `dev-api` |
| `make sqlite-api` | Abre la base con `sqlite3` |
| `make smoke-test` | Levanta `dev-api` si hace falta y chequea `/health` |
| `make verify` | `db-rebuild` + tipos + `smoke-test`. **No corre los tests** |
| `make clean` | Para todo y **borra los volúmenes** (perdés los datos) |
| `make prod` | Compila y corre producción local |
| `make reload-env` | Recrea `dev-api` y `dev-worker` para tomar cambios del `.env` |

---

## Producción

`prod-api` toma `../api` como contexto. El Dockerfile en
`ops/docker/prod-api/Dockerfile` es multi-stage: primero compila la UI desde
`../ui-astro`, y después copia el bundle estático adentro del servidor Elysia. La
API sirve los endpoints y los estáticos **en un solo puerto**, así que no hace falta
un contenedor aparte para el frontend ni hay CORS de por medio.

```sh
make prod          # build + prod-api + prod-worker
make prod-api      # solo la API
```

```txt
http://localhost:8081
```

---

## Notas

**Los datos viven en volúmenes con nombre.** El de dev es `dev-api-sqlite-data` y
el de producción `prod-api-sqlite-data`; **en los dos casos lo comparten el api y el
worker**, porque el worker también escribe. `docker compose down -v` los borra.

**Los comprobantes** (`data/receipts/`) viven dentro de ese mismo volumen, con el
sha256 como nombre de archivo. No se sirven por HTTP: son la prueba de un pago, no
un asset público.

Si antes corrías la `dev-ui` vieja (la de Vue), sus volúmenes ya no se usan. Borralos
una vez:

```sh
docker volume rm peonveloz_dev-ui-node-modules peonveloz_dev-ui-bun-cache
```

Si Docker Desktop no puede montar tus carpetas, agregá esos caminos en la
configuración de file sharing, o cambiá `UI_PATH` o `API_PATH` en `.env.development`.
