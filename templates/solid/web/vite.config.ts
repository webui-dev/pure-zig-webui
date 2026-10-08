import { defineConfig } from "vite";
import solid from "vite-plugin-solid";

export default defineConfig({
  plugins: [solid()],
  // zig-webui serves web/dist below a per-window path.
  base: "./",
  // The linked zig-webui SDK must share this app's framework instance.
  resolve: { dedupe: ["solid-js"] },
  // `zig build dev` opens this port.
  server: { port: 5173, strictPort: true },
});
