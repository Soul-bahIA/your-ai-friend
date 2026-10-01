import type { AnalyzeResponse } from "../api/client";

export function ResultCard({ result }: { result: AnalyzeResponse }) {
  const { label, score, compute, requestId } = result;

  const stats: [string, number][] = [
    ["Éléments", compute.count],
    ["Moyenne", compute.mean],
    ["Écart-type", compute.std_dev],
    ["Norme", compute.norm],
    ["Premiers < 100k", compute.primes_under_limit],
  ];

  return (
    <div className="card result">
      <div className="result__head">
        <span className={`badge badge--${label === "positif" ? "pos" : "neg"}`}>
          {label}
        </span>
        <span className="score">confiance {(score * 100).toFixed(0)}%</span>
      </div>

      <div className="stats">
        {stats.map(([key, value]) => (
          <div key={key} className="stat">
            <span className="stat__value">
              {Number.isInteger(value) ? value : value.toFixed(2)}
            </span>
            <span className="stat__label">{key}</span>
          </div>
        ))}
      </div>

      <p className="reqid">
        Traité par Node → Python → Rust · id {requestId.slice(0, 8)}
      </p>
    </div>
  );
}
