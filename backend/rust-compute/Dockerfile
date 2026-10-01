# --- Étape de build ---
# NOTE Cargo.lock (T50) : aucun Cargo.lock n'est versionné (pas de toolchain Rust sur
# le poste de dev). Pour des builds reproductibles, sur une machine avec cargo :
#   cd backend/rust-compute && cargo generate-lockfile && git add Cargo.lock
# puis ajouter `COPY Cargo.lock ./` ci-dessous et passer les deux `cargo build` en
# `cargo build --release --locked`.
FROM rust:1.82-slim AS builder
WORKDIR /app

# Pré-cache des dépendances (couche Docker réutilisée tant que Cargo.toml ne change pas)
COPY Cargo.toml ./
RUN mkdir src && echo "fn main() {}" > src/main.rs && cargo build --release && rm -rf src

# Build réel
COPY src ./src
RUN touch src/main.rs && cargo build --release

# --- Image finale (légère, utilisateur NON-root) ---
FROM debian:bookworm-slim
RUN groupadd --system --gid 10002 compute \
    && useradd --system --uid 10002 --gid compute --no-create-home --shell /usr/sbin/nologin compute
WORKDIR /app
COPY --from=builder /app/target/release/rust-compute /usr/local/bin/rust-compute
USER compute
EXPOSE 8080
CMD ["rust-compute"]
