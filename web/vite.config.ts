import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// The page is served by Vite in development; every /api call goes to the local API server.
// The proxy tells the API server who really asked (`x-understood-peer`), because through the
// proxy every request arrives from this machine. The local-only TORGO route uses it, so the
// recordings stay on this computer even if Vite is started with --host.
export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    proxy: {
      "/api": {
        target: "http://localhost:8787",
        changeOrigin: true,
        configure: (proxy) => {
          proxy.on("proxyReq", (proxyReq, req) => {
            proxyReq.setHeader("x-understood-peer", req.socket?.remoteAddress ?? "unknown");
          });
        },
      },
    },
  },
});
