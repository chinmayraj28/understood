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
    // A temporary public demo link (Cloudflare quick tunnel); the API stays keyword-locked.
    allowedHosts: [".trycloudflare.com"],
    proxy: {
      "/api": {
        target: "http://127.0.0.1:8787",
        changeOrigin: true,
        configure: (proxy) => {
          proxy.on("proxyReq", (proxyReq, req) => {
            proxyReq.setHeader("x-understood-peer", req.socket?.remoteAddress ?? "unknown");
            // The address the visitor typed. Through a tunnel every request arrives from this
            // machine, so only the original host shows it came from outside.
            proxyReq.setHeader("x-understood-host", req.headers.host ?? "unknown");
          });
        },
      },
    },
  },
});
