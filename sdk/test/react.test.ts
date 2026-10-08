import assert from "node:assert/strict";
import { test } from "node:test";
import { Window } from "happy-dom";
import { fakeBridge } from "./env.ts";

const g = globalThis as Record<string, unknown>;
const window = new Window({ url: "http://127.0.0.1:4100/" });
Object.assign(g, { window, document: window.document, IS_REACT_ACT_ENVIRONMENT: true });
const bridge = fakeBridge(false);
g.webui = bridge;

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { renderToString } = await import("react-dom/server");
const { useBridge, useConnected } = await import("../src/react.ts");

function Status() {
    const connected = useConnected();
    const loaded = useBridge();
    return createElement("p", null, `${connected}:${loaded === bridge}`);
}

test("React hooks follow bridge connection changes and stop on unmount", async () => {
    assert.equal(renderToString(createElement(Status)), "<p>false:false</p>");

    const container = window.document.createElement("div");
    const root = createRoot(container as unknown as Element);
    await act(async () => root.render(createElement(Status)));
    assert.equal(container.textContent, "false:true");
    assert.equal(bridge.hasCallback, true);

    await act(async () => bridge.emit(true));
    assert.equal(container.textContent, "true:true");
    await act(async () => bridge.emit(false));
    assert.equal(container.textContent, "false:true");

    await act(async () => root.unmount());
    bridge.emit(true);
    assert.equal(container.textContent, "");
});
