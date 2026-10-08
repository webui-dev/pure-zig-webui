# __NAME__

A [zig-webui](https://github.com/webui-dev/pure-zig-webui) desktop app with a
__FRAMEWORK__ + Vite frontend.

```sh
cd web && npm install && cd ..
zig build run          # build web/dist and open the app
```

Development with hot reload, in two terminals:

```sh
cd web && npm run dev  # Vite on http://localhost:5173
zig build dev          # open the app against the dev server
```

Zig bindings live in `src/main.zig`; the frontend calls them through the
`zig-webui` SDK (`web/src`).
