import { defineConfig, loadEnv } from "vite";
import react from "@vitejs/plugin-react-swc";
import path from "path";

// https://vitejs.dev/config/
export default defineConfig(({ mode }) => {
  // Serveur de dev : n'écoute que sur la machine locale par défaut (S16).
  // VITE_DEV_HOST=0.0.0.0 (ou "::") pour l'exposer volontairement au réseau local.
  const env = loadEnv(mode, process.cwd(), "VITE_");
  const host = process.env.VITE_DEV_HOST?.trim() || env.VITE_DEV_HOST?.trim() || "localhost";

  return {
    server: {
      host,
      port: 8080,
      hmr: {
        overlay: false,
      },
    },
    plugins: [react()],
    resolve: {
      alias: {
        "@": path.resolve(__dirname, "./src"),
      },
    },
    build: {
      rollupOptions: {
        output: {
          manualChunks: {
            "vendor-react": ["react", "react-dom", "react-router-dom"],
            "vendor-supabase": ["@supabase/supabase-js"],
            "vendor-query": ["@tanstack/react-query"],
          },
        },
      },
    },
  };
});
