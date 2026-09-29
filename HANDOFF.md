# Traspaso

Escrito el 2026-09-29 para retomar el trabajo en una conversación nueva.

**Este archivo es el estado y los pendientes.** Para entender *cómo funciona* el
flujo, leé `README.md` (mismo directorio) — está al día.

---

## Cómo arrancar

```sh
cd ops
make help          # lista todos los comandos con su descripción
make up            # dev-api + dev-ui + dev-worker
make api-test      # 32 pass, 0 fail
```

| Qué | Dónde |
|---|---|
| UI (Astro) | http://localhost:4321 |
| API | http://localhost:4000 |
| Swagger | http://localhost:4000/swagger |

## El flujo, en una línea

WhatsApp (última palabra del mensaje = slug) → `/register` → *(si el torneo es
online)* `/verificar-lichess` → `/checkout` → **pago, que no existe**.

---

## Estado del código

Todo commiteado **y pusheado** a `origin/main` en los tres repos
(`caifel/peon-veloz-api`, `-ui-astro`, `-ops`). Este archivo es el commit más
reciente de `ops`; no pongas acá su propio hash, porque cada cambio lo invalida.

Los cambios de esta etapa, por repo:

| Repo | Commits |
|---|---|
| `api` | `293b35d` modelo mínimo · `8080775` Lichess server-side · `3504b2d` resolveEntryCta · `a0fe5e3` tests |
| `ui-astro` | `147c58f` vistas del flujo · `4c13c22` tipos regenerados |
| `ops` | `071f1c0` README y generate-url · `…` este traspaso |

Si querés saber si algo quedó sin subir: `git log --oneline @{u}..HEAD` en cada repo.

---

## Hecho y verificado — no rehacer

- **P1 cerrado.** `POST /api/auth/register` no acepta identidad de Lichess: solo
  crea la persona. La cuenta la escribe el **callback**, server-side, que es lo
  que impide que alguien se registre con la cuenta de otro. El navegador nunca
  ve ni envía esa identidad.
- **La regla de entrada vive en un solo lugar:** `api/src/lib/whatsapp/entry-cta.ts`
  (`resolveEntryCta`) → `{destination, url, bodyText, buttonText, reason}`. La
  usan el dispatcher y `make generate-url`, así que no pueden divergir. El texto
  del botón viaja junto al destino a propósito (el bug que tuvimos fue ese: el
  botón decía "Realizar pago" y aterrizaba en el login de Lichess).
- **`/verificar-lichess` no confirma nada:** cuando el estado es `ok` la cuenta
  ya está guardada, así que muestra el overlay y sigue sola al `next`. Los
  errores se parten en dos: reintentables, y `user_not_found` → `/expired`.
- **Diseño unificado** en `ui-astro/src/components/PageShell.astro` (header +
  acción fija abajo) y `Loading.astro`. El CSS sale de `register`, que es la
  referencia.
- **`tournaments` reducido a 9 campos**; `donations` y `prizes` eliminadas.
- **Suite en verde:** 32 pass, 0 fail (`make api-test`).

---

## Pendientes, por prioridad

### P0 — higiene y lo único sin probar

1. **Probar el OAuth feliz con una cuenta real de Lichess.** Es lo único del
   flujo nuevo que nunca se verificó de punta a punta. `MIN_RATED_GAMES = 100`
   en `api/src/lib/lichess-oauth.ts:18` bloquea cuentas nuevas: bajalo
   temporalmente para poder completar el flujo y después devolvelo.
2. **El loop de "Probar con otra cuenta".** Con la sesión de Lichess ya
   iniciada, el popup reautoriza la misma cuenta y falla igual, sin salida
   visible. Falta copy explícito y/o un link al logout de Lichess.
   (Verificá la URL de logout de Lichess antes de ponerla.)
3. **Pushear.**

### P1 — la causa raíz de que varias cosas se escondieran

**No hay typecheck.** `typescript` no está en `api/package.json`, no hay script,
y `api/tsconfig.json:31` tiene `moduleResolution: "node"`, que las versiones
modernas de tsc rechazan. Bun transpila sin chequear tipos, así que un error de
tipos no aparece hasta runtime — **por eso** `routes/users.ts` pudo quedarse
referenciando columnas inexistentes sin que nadie lo note.

Agregar `typescript`, arreglar esa opción, un script `make typecheck`, y sumarlo
a `make verify` y al pre-commit hook. Con eso, los pendientes de P2 se vuelven
imposibles de esconder.

### P2 — código muerto

- `api/src/routes/users.ts` y `api/src/routes/tournaments.ts`: desmontadas en
  `api/src/app.ts`, escritas contra un esquema que no existe
  (`users.address`, `tournaments.category/timeControl/...`). Borrar o
  reconciliar — pero no dejarlas ahí.
- `UserSummary` en `api/src/lib/schemas.ts:93`: 0 usos.
- El flujo de sesión de `api/src/lib/auth.ts` + la tabla `sessions`: sin
  consumidor, porque no hay `/login`.

### P3 — producto

- **La página del torneo.** `ui-astro/src/pages/tournament.astro` es un
  esqueleto que ni siquiera usa el `?slug=` que recibe, y **el botón
  INSCRIBIRSE no existe**. Eso bloquea la recuperación de `/expired`, cuyos 5
  pasos describen justamente ese botón. Hace falta además el **número público
  del bot** en la config (`WHATSAPP_PHONE_NUMBER_ID` es el ID de Meta, no sirve
  para un link `wa.me`). Ojo: el mensaje prearmado tiene que **terminar en el
  slug**, porque el dispatcher lee la última palabra.
- **La inscripción y el pago.** El checkout es un placeholder y `inscriptions`
  no se usa. Hay que decidir cómo se cobra, y si la inscripción espera
  confirmación de pago.
- **Exponer `inscriptionPrice`.** La columna existe pero ninguna API la
  devuelve, así que el checkout no puede mostrar el precio. Es lo que le falta
  para ser una pantalla de pago de verdad.
- **`pageHtml` existe y no se renderiza.** Falta decidir la sanitización: es un
  vector de stored XSS, y sin login no hay forma de restringir quién crea
  torneos. Opciones: sanitizar con allowlist, iframe con sandbox, o markdown.

### P4 — detalles

- `/expired` y `/tournament` siguen fuera del `PageShell` (`/expired` no tiene
  header), así que rompen la consistencia del resto.
- `ui-astro/src/pages/register.astro` muestra el JSON crudo en un 409
  (`{"error":{"code":"CONFLICT",...}}`) y usa `innerHTML`.
- **El webhook no verifica la firma si el header no viene**
  (`api/src/routes/webhook-meta.ts:41`), y `.env.development` tiene un token real
  de Meta: cualquiera que llegue a la API puede hacer que el bot mande WhatsApp
  a cualquier número.
- `deriveRedirectUri` ignora un `LICHESS_REDIRECT_URI` configurado, y las rutas
  de Lichess no tienen rate limit.

---

## Trampas que hacen perder tiempo

1. **El sender de WhatsApp llama de verdad a `graph.facebook.com`.** Si el
   worker está arriba, postear al webhook **manda un WhatsApp real**. Para
   inspeccionar sin enviar:

   ```sh
   docker compose --env-file .env.development stop dev-worker
   # …postear al webhook…
   docker compose --env-file .env.development exec -T redis redis-cli LRANGE whatsapp:queue 0 -1
   docker compose --env-file .env.development exec -T redis redis-cli DEL whatsapp:queue
   docker compose --env-file .env.development start dev-worker
   ```

2. **`redis-cli LRANGE` imprime un elemento por línea, no un array JSON.** No le
   apliques `.[]` en `jq`.
3. **El puerto 4321 colisiona** con un `astro dev` corriendo en el host.
4. **Teléfonos del seed para probar:** `77777777` (Admin, **sin** cuenta de
   Lichess → manda a verificar) y `780000000` (Carlos, **con** cuenta → va
   directo a pagar).
5. **`make api-test` corre dentro del container** y arma la base de test leyendo
   `api/drizzle/`. Si no hay migraciones, ahora tira un error explícito en vez de
   fallar de formas raras.
6. **`make generate-url PHONE=… SLUG=…`** te da el link que ese teléfono
   recibiría, sin WhatsApp, y explica por qué eligió ese destino. Es la forma más
   rápida de probar cualquier camino.

## Slugs del seed

`torneo-intercolegial` y `torneo-copa-paz` activos y presenciales,
`torneo-relampago` inactivo, y `torneo-online-arena` el único **online**.
