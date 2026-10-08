import assert from "node:assert/strict";
import { test } from "node:test";
import { createEffect, createRoot } from "solid-js";
import { fakeBridge } from "./env.ts";

const bridge = fakeBridge(false);
(globalThis as Record<string, unknown>).webui = bridge;
const { createBridge, createConnected } = await import("../src/solid.ts");

test("Solid primitives are reactive signals disposed with their owner", () => {
    const seen: boolean[] = [];
    const { connected, loaded, dispose } = createRoot((dispose) => {
        const connected = createConnected();
        createEffect(() => seen.push(connected()));
        return { connected, loaded: createBridge(), dispose };
    });
    assert.equal(loaded(), bridge);
    assert.deepEqual(seen, [false]);

    bridge.emit(true);
    assert.equal(connected(), true);
    assert.deepEqual(seen, [false, true]);
    dispose();
    bridge.emit(false);
    assert.equal(connected(), true);
});
