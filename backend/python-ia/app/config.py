import os

# URL du service Rust (calculs intensifs), fournie par docker-compose.
RUST_SERVICE_URL = os.getenv("RUST_SERVICE_URL", "http://rust-compute:8080")
