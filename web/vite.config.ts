import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// The page is served by Vite in development; every /api call goes to the local API server.
export default defineConfig({
  plugins: [react()],
  server: { port: 5173, proxy: { "/api": "http://localhost:8787" } },
});
