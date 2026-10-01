import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    // Local uniquement par défaut (S16) ; VITE_DEV_HOST=0.0.0.0 pour l'exposer.
    host: process.env.VITE_DEV_HOST?.trim() || "localhost",
  },
});
