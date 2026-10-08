import assert from "node:assert/strict";
import { test } from "node:test";
import { effectScope, isReadonly } from "vue";
import { fakeBridge } from "./env.ts";

const bridge = fakeBridge(true);
(globalThis as Record<string, unknown>).webui = bridge;
const { useBridge, useConnected } = await import("../src/vue.ts");

test("Vue composables expose read-only refs released with their scope", () => {
    const scope = effectScope();
    const { connected, loaded } = scope.run(() => ({ connected: useConnected(), loaded: useBridge() }))!;
    assert.equal(connected.value, true);
    assert.equal(loaded.value, bridge);
    assert.equal(isReadonly(connected), true);

    bridge.emit(false);
    assert.equal(connected.value, false);
    scope.stop();
    bridge.emit(true);
    assert.equal(connected.value, false);
});
