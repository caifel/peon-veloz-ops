# Stage 1: Build Astro frontend
FROM node:22-slim AS ui-builder
WORKDIR /ui-astro
COPY ui-astro/package.json ui-astro/package-lock.json ./
RUN npm ci
COPY ui-astro/ ./
RUN npm run build

# Stage 2: Build and run API
FROM oven/bun:1-debian AS runner
WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      ca-certificates \
      sqlite3 \
      libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*

COPY api/package.json api/bun.lock* ./
RUN bun install --frozen-lockfile

COPY api/ ./
COPY --from=ui-builder /ui-astro/dist ./public

ENV NODE_ENV=production

RUN groupadd --gid 10001 appgroup \
    && useradd --uid 10001 --gid appgroup --create-home --shell /usr/sbin/nologin appuser \
    && mkdir -p /app/data \
    && chown -R appuser:appgroup /app

USER appuser
EXPOSE 8081
CMD ["sh", "-c", "bun run db:migrate && bun run start"]
