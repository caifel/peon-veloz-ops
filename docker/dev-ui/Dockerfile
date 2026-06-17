FROM oven/bun:1-debian

ARG USERNAME=mario

ENV BUN_INSTALL=/home/${USERNAME}/.bun \
    PATH=/home/${USERNAME}/.bun/bin:$PATH

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      openssl \
    && usermod --login ${USERNAME} --move-home --home /home/${USERNAME} bun \
    && groupmod --new-name ${USERNAME} bun \
    && mkdir -p /home/${USERNAME}/.bun/install/cache /peonveloz/ui/node_modules \
    && chown -R ${USERNAME}:${USERNAME} /home/${USERNAME} /peonveloz/ui \
    && rm -rf /var/lib/apt/lists/*

USER ${USERNAME}
WORKDIR /peonveloz/ui

CMD ["bun", "--bun", "run", "dev", "--hostname", "0.0.0.0"]
