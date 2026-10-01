// Petit cache mémoire à durée de vie bornée et taille bornée (éviction FIFO).

export class TtlCache<V> {
  private map = new Map<string, { value: V; expires: number }>();

  constructor(
    private maxEntries: number,
    private defaultTtlMs: number,
    private now: () => number = () => Date.now(),
  ) {}

  get(key: string): V | undefined {
    const hit = this.map.get(key);
    if (!hit) return undefined;
    if (hit.expires <= this.now()) {
      this.map.delete(key);
      return undefined;
    }
    return hit.value;
  }

  set(key: string, value: V, ttlMs = this.defaultTtlMs): void {
    if (ttlMs <= 0) return;
    this.map.delete(key);
    while (this.map.size >= this.maxEntries) {
      const oldest = this.map.keys().next().value;
      if (oldest === undefined) break;
      this.map.delete(oldest);
    }
    this.map.set(key, { value, expires: this.now() + ttlMs });
  }

  delete(key: string): void {
    this.map.delete(key);
  }

  get size(): number {
    return this.map.size;
  }
}
