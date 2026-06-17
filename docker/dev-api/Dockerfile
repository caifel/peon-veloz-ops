FROM oven/bun:1-debian

ARG USERNAME=mario

ENV NODE_ENV=development

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      ca-certificates \
      git \
      openssl \
      sqlite3 \
      libsqlite3-dev \
    && usermod --login ${USERNAME} --move-home --home /home/${USERNAME} bun \
    && groupmod --new-name ${USERNAME} bun \
    && mkdir -p /home/${USERNAME}/.bun/install/cache /peonveloz/api/node_modules /peonveloz/api/data \
    && chown -R ${USERNAME}:${USERNAME} /home/${USERNAME} /peonveloz/api \
    && rm -rf /var/lib/apt/lists/*

USER ${USERNAME}
WORKDIR /peonveloz/api

CMD ["bun", "run", "dev"]
