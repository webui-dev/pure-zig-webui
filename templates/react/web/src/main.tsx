// Import the SDK first: it takes the dev-server bridge URL out of the
// address bar before anything else reads it.
import "zig-webui";
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import "./style.css";

createRoot(document.getElementById("app")!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
