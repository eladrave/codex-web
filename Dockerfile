# syntax=docker/dockerfile:1.7

ARG NODE_IMAGE=node:22-bookworm-slim

FROM ${NODE_IMAGE} AS builder

ARG CODEX_APP_VERSION=26.727.51351
ENV NODE_ENV=production

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    g++ \
    make \
    patch \
    python3 \
    unzip \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --include=dev --ignore-scripts \
  && npm rebuild better-sqlite3 node-pty

COPY assets/ ./assets/
COPY patches/ ./patches/
COPY scripts/enable_linux_remote_control_keys.mjs ./scripts/enable_linux_remote_control_keys.mjs
COPY scripts/prepare_asar ./scripts/prepare_asar
COPY scripts/smoke_test_terminal_pty.mjs ./scripts/smoke_test_terminal_pty.mjs
COPY src/ ./src/
COPY vite.browser.config.ts ./

RUN curl --fail --location --retry 3 --retry-delay 2 \
    --output /tmp/codex-app.zip \
    "https://persistent.oaistatic.com/codex-app-prod/ChatGPT-darwin-arm64-${CODEX_APP_VERSION}.zip" \
  && HOSTED_CODEX_APP_ZIP=/tmp/codex-app.zip npm run build \
  && node scripts/smoke_test_terminal_pty.mjs \
  && rm -rf /tmp/codex-app.zip scratch/ChatGPT.app \
  && npm prune --omit=dev --ignore-scripts \
  && chmod -R a+rX /app

FROM ${NODE_IMAGE} AS runtime

ARG CODEX_VERSION=0.146.0
ARG GCLOUD_VERSION=578.0.0-0
ARG GH_VERSION=2.97.0

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
  && install -d -m 755 /etc/apt/keyrings \
  && curl --fail --silent --show-error --location \
    https://packages.cloud.google.com/apt/doc/apt-key.gpg \
    | gpg --dearmor -o /etc/apt/keyrings/cloud.google.gpg \
  && curl --fail --silent --show-error --location \
    --output /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  && chmod a+r \
    /etc/apt/keyrings/cloud.google.gpg \
    /etc/apt/keyrings/githubcli-archive-keyring.gpg \
  && printf '%s\n' \
    'deb [signed-by=/etc/apt/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main' \
    > /etc/apt/sources.list.d/google-cloud-sdk.list \
  && printf '%s\n' \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list \
  && apt-get update \
  && apt-get install -y --no-install-recommends \
    build-essential \
    fd-find \
    file \
    gh="${GH_VERSION}" \
    git \
    git-lfs \
    google-cloud-cli="${GCLOUD_VERSION}" \
    iproute2 \
    iputils-ping \
    jq \
    less \
    lsof \
    nano \
    netcat-openbsd \
    openssh-client \
    pkg-config \
    procps \
    psmisc \
    python-is-python3 \
    python3 \
    python3-dev \
    python3-pip \
    python3-venv \
    ripgrep \
    rsync \
    sqlite3 \
    tini \
    tree \
    unzip \
    xz-utils \
    zip \
  && npm install --global "@openai/codex@${CODEX_VERSION}" \
  && ln -s /usr/bin/fdfind /usr/local/bin/fd \
  && git lfs install --system --skip-repo \
  && useradd --create-home --shell /bin/bash --uid 10001 codex \
  && install -d -o codex -g codex -m 700 \
    /data \
    /home/codex/.ssh \
    /run/secrets/codex-ssh \
  && rm -rf /var/lib/apt/lists/* /root/.npm

WORKDIR /app

COPY --from=builder /app /app
COPY docker/entrypoint.sh /usr/local/bin/codex-web-entrypoint
COPY docker/oauth-callback-bridge.mjs /usr/local/lib/codex-web/oauth-callback-bridge.mjs
COPY docker/state-sync.mjs /usr/local/lib/codex-web/state-sync.mjs
RUN chmod 0755 /usr/local/bin/codex-web-entrypoint \
  && chmod 0644 \
    /usr/local/lib/codex-web/oauth-callback-bridge.mjs \
    /usr/local/lib/codex-web/state-sync.mjs

ENV CODEX_CLI_PATH=/usr/local/bin/codex \
  CODEX_HOME=/data/codex \
  CODEX_SSH_SOURCE_DIR=/run/secrets/codex-ssh \
  CODEX_WEB_OAUTH_CALLBACK_BRIDGE=1 \
  CODEX_WEB_OAUTH_CALLBACK_PORTS=1455,1457 \
  CODEX_WEB_SOFTWARE_DEVICE_KEYS=1 \
  CODEX_WEB_DATA_DIR=/data \
  CODEX_WEB_HOST=0.0.0.0 \
  HOME=/home/codex \
  NODE_ENV=production \
  PORT=8080

USER codex

EXPOSE 8080 1455 1457
VOLUME ["/data"]

HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=4 \
  CMD ["node", "-e", "fetch('http://127.0.0.1:' + (process.env.PORT || '8080') + '/__backend/healthz').then(r => { if (!r.ok) process.exit(1) }).catch(() => process.exit(1))"]

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/codex-web-entrypoint"]
