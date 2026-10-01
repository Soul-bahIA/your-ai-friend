# --- Étape de build ---
FROM rust:1.82-slim AS builder
WORKDIR /app

# Pré-cache des dépendances (couche Docker réutilisée tant que Cargo.toml ne change pas)
COPY Cargo.toml ./
RUN mkdir src && echo "fn main() {}" > src/main.rs && cargo build --release && rm -rf src

# Build réel
COPY src ./src
RUN touch src/main.rs && cargo build --release

# --- Image finale (légère) ---
FROM debian:bookworm-slim
WORKDIR /app
COPY --from=builder /app/target/release/rust-compute /usr/local/bin/rust-compute
EXPOSE 8080
CMD ["rust-compute"]
