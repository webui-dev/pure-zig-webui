import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

export default defineConfig({
  plugins: [react()],
  // zig-webui serves web/dist below a per-window path.
  base: "./",
  // The linked zig-webui SDK must share this app's framework instance.
  resolve: { dedupe: ["react", "react-dom"] },
  // `zig build dev` opens this port.
  server: { port: 5173, strictPort: true },
});
