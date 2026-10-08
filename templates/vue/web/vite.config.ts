import vue from "@vitejs/plugin-vue";
import { defineConfig } from "vite";

export default defineConfig({
  plugins: [vue()],
  // zig-webui serves web/dist below a per-window path.
  base: "./",
  // The linked zig-webui SDK must share this app's framework instance.
  resolve: { dedupe: ["vue"] },
  // `zig build dev` opens this port.
  server: { port: 5173, strictPort: true },
});
