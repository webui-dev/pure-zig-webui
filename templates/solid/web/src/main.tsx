// Import the SDK first: it takes the dev-server bridge URL out of the
// address bar before anything else reads it.
import "zig-webui";
import { render } from "solid-js/web";
import { App } from "./App";
import "./style.css";

render(() => <App />, document.getElementById("app")!);
