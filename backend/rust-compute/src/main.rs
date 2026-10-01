use axum::{
    routing::{get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use std::net::SocketAddr;

#[derive(Deserialize)]
struct ComputeRequest {
    values: Vec<f64>,
}

#[derive(Serialize)]
struct ComputeResponse {
    count: usize,
    sum: f64,
    mean: f64,
    std_dev: f64,
    norm: f64,
    // Exemple de calcul CPU-bound "intensif" : nombres premiers sous une limite.
    primes_under_limit: usize,
}

async fn health() -> Json<serde_json::Value> {
    Json(serde_json::json!({ "status": "ok", "service": "rust-compute" }))
}

async fn compute(Json(req): Json<ComputeRequest>) -> Json<ComputeResponse> {
    let v = &req.values;
    let count = v.len();
    let sum: f64 = v.iter().sum();
    let mean = if count > 0 { sum / count as f64 } else { 0.0 };

    let variance = if count > 0 {
        v.iter().map(|x| (x - mean).powi(2)).sum::<f64>() / count as f64
    } else {
        0.0
    };
    let std_dev = variance.sqrt();
    let norm = v.iter().map(|x| x * x).sum::<f64>().sqrt();

    // Charge de calcul de démonstration (remplacez par votre vrai calcul lourd).
    let primes_under_limit = count_primes(100_000);

    Json(ComputeResponse {
        count,
        sum,
        mean,
        std_dev,
        norm,
        primes_under_limit,
    })
}

/// Crible d'Ératosthène : compte les nombres premiers strictement inférieurs à `limit`.
fn count_primes(limit: usize) -> usize {
    if limit < 2 {
        return 0;
    }
    let mut sieve = vec![true; limit];
    sieve[0] = false;
    sieve[1] = false;
    let mut i = 2;
    while i * i < limit {
        if sieve[i] {
            let mut j = i * i;
            while j < limit {
                sieve[j] = false;
                j += i;
            }
        }
        i += 1;
    }
    sieve.iter().filter(|&&b| b).count()
}

#[tokio::main]
async fn main() {
    let app = Router::new()
        .route("/health", get(health))
        .route("/compute", post(compute));

    let addr = SocketAddr::from(([0, 0, 0, 0], 8080));
    println!("rust-compute en écoute sur http://{addr}");

    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}
