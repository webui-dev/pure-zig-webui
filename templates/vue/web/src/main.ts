// Import the SDK first: it takes the dev-server bridge URL out of the
// address bar before anything else reads it.
import "zig-webui";
import { createApp } from "vue";
import App from "./App.vue";
import "./style.css";

createApp(App).mount("#app");
