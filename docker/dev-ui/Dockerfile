# Development image for the Astro UI (../ui-astro).
#
# Uses Node 22 to match the production Astro build stage in
# ops/docker/prod-api/Dockerfile, so `npm install` behaves the same here and
# in the prod image.
FROM node:22-slim

ENV NPM_CONFIG_UPDATE_NOTIFIER=false \
    NPM_CONFIG_FUND=false

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      openssl \
    && mkdir -p /home/node/.npm /peonveloz/ui-astro/node_modules \
    && chown -R node:node /home/node /peonveloz/ui-astro \
    && rm -rf /var/lib/apt/lists/*

USER node
WORKDIR /peonveloz/ui-astro

EXPOSE 4321

CMD ["npm", "run", "dev"]
