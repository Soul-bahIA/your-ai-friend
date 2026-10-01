# --- Étape de build ---
# Cargo.lock (T50) : le Dockerfile est PRÊT pour des builds verrouillés. Dès qu'un
# Cargo.lock est versionné à côté de Cargo.toml, il est copié et les deux
# `cargo build` passent automatiquement en `--locked` (échec si le lock est périmé,
# au lieu de résoudre silencieusement d'autres versions). Le générer sur une machine
# disposant de cargo (aucune toolchain Rust sur le poste de dev actuel) :
#   cd backend/rust-compute && cargo generate-lockfile && git add Cargo.lock
# Sans Cargo.lock, le build reste possible mais NON reproductible (avertissement).
FROM rust:1.82-slim AS builder
WORKDIR /app

# Pré-cache des dépendances (couche Docker réutilisée tant que Cargo.toml/Cargo.lock
# ne changent pas). `Cargo.lock*` : copié s'il existe, ignoré sinon.
COPY Cargo.toml Cargo.lock* ./
RUN if [ -f Cargo.lock ]; then echo "--locked" > /tmp/cargo-lock-flag; \
    else echo "AVERTISSEMENT T50 : pas de Cargo.lock, build non reproductible" >&2; : > /tmp/cargo-lock-flag; fi \
    && mkdir src && echo "fn main() {}" > src/main.rs \
    && cargo build --release $(cat /tmp/cargo-lock-flag) && rm -rf src

# Build réel
COPY src ./src
RUN touch src/main.rs && cargo build --release $(cat /tmp/cargo-lock-flag)

# --- Image finale (légère, utilisateur NON-root) ---
FROM debian:bookworm-slim
RUN groupadd --system --gid 10002 compute \
    && useradd --system --uid 10002 --gid compute --no-create-home --shell /usr/sbin/nologin compute
WORKDIR /app
COPY --from=builder /app/target/release/rust-compute /usr/local/bin/rust-compute
USER compute
EXPOSE 8080
CMD ["rust-compute"]
