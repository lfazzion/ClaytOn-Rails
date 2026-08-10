# syntax=docker/dockerfile:1

# ── Build Stage ──────────────────────────────────────────────────────────────
FROM ruby:4-slim AS build

# Dependências bare-metal — sem Node.js/Sprockets (app é Headless Zero HTML)
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
      build-essential \
      libsqlite3-dev \
      curl \
      git \
      libyaml-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /rails

# Instala gems antes de copiar o código (cache layer)
COPY Gemfile Gemfile.lock ./
RUN bundle config set --local without 'development' && \
    bundle install && \
    bundle exec bootsnap precompile --gemfile

# Copia o restante da aplicação
COPY . .

# Pre-compila bootsnap para inicialização mais rápida
RUN bundle exec bootsnap precompile app/ lib/

# ── Runtime Stage ─────────────────────────────────────────────────────────────
FROM ruby:4-slim AS runtime

RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
      libsqlite3-0 \
      sqlite3 \
      curl \
      python3 \
      python3-pip \
      ffmpeg \
      unzip \
    && rm -rf /var/lib/apt/lists/*

# yt-dlp — coleta YouTube sem browser + solver pinado ejs
RUN pip3 install --no-cache-dir --break-system-packages yt-dlp==2026.07.04 yt-dlp-ejs==0.8.0

ARG TARGETARCH

# Deno 2.9.5 — runtime JavaScript para yt-dlp
RUN case "${TARGETARCH:-amd64}" in \
        "arm64"|"aarch64") \
            DENO_ARCH="aarch64-unknown-linux-gnu" \
            DENO_SHA256="6b7cae3a8fc4385a59dea3146fcb8bad7fea4230e0ad36a8c692afacbc254be0" ;; \
        *) \
            DENO_ARCH="x86_64-unknown-linux-gnu" \
            DENO_SHA256="8b010a3b1a4a0188a67cdb8a7a27348b2a501af78aec7fc74f2ace167368d530" ;; \
    esac && \
    curl -fsSL "https://github.com/denoland/deno/releases/download/v2.9.5/deno-${DENO_ARCH}.zip" -o /tmp/deno.zip && \
    echo "${DENO_SHA256}  /tmp/deno.zip" | sha256sum -c - && \
    unzip /tmp/deno.zip -d /usr/local/bin && \
    chmod +x /usr/local/bin/deno && \
    rm /tmp/deno.zip && \
    /usr/local/bin/deno --version

WORKDIR /rails

# Copia gems e código compilado do build stage
COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --from=build /rails /rails

# Corrige permissões de binários antes de criar usuário
RUN chmod +x /rails/bin/rails /rails/bin/rake /rails/bin/entrypoint /rails/bin/entrypoint-jobs /rails/bin/jobs /rails/bin/discord-bot 2>/dev/null || true

# Diretório de banco persistido via bind mount em produção
RUN mkdir -p storage

# Não rodar como root - faz tudo como root primeiro
RUN useradd -m -s /bin/bash rails && chown -R rails:rails /rails

USER rails

EXPOSE 3000

# Entrypoint específico para jobs que garante migrations
ENTRYPOINT ["bin/entrypoint-jobs"]
CMD ["bin/rails", "server", "-b", "0.0.0.0"]
