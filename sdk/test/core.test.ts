import assert from "node:assert/strict";
import { beforeEach, test } from "node:test";
import { bridgeSource, fakeBridge, FakeSocket, frame, installBrowser, tick } from "./env.ts";

type Sdk = typeof import("../src/index.ts");
let generation = 0;
// Every import gets a fresh module instance, like a new page load.
const loadSdk = (): Promise<Sdk> => import(`../src/index.ts?page=${++generation}`);
const g = globalThis as Record<string, unknown>;
const capability = "0123456789abcdef0123456789abcdef";
const bridgeUrl = `http://127.0.0.1:4100/${capability}/webui.js`;
const served = `globalThis.__zigWebuiToken=7;\nglobalThis.__zigWebuiCapability="${capability}";\n${bridgeSource}`;

beforeEach(() => {
    delete g.webui;
    delete g.__zigWebuiLoading;
    FakeSocket.all.length = 0;
});

test("dev server fragment loads the real bridge, connects, and calls Zig", async () => {
    const env = installBrowser(
        `http://localhost:5173/app?x=1#a=1&webui-bridge=${encodeURIComponent(bridgeUrl)}`,
    );
    env.serve.set(bridgeUrl, served);
    const sdk = await loadSdk();
    // The fragment is gone before application code runs, other keys stay.
    assert.deepEqual(env.replaced, ["/app?x=1#a=1"]);
    assert.equal(env.storage.get("zig-webui:bridge-url"), bridgeUrl);

    const changes: boolean[] = [];
    sdk.subscribe(() => changes.push(sdk.isConnected()));
    const bridge = await sdk.loadBridge();
    assert.equal(sdk.getBridge(), bridge);
    assert.deepEqual(env.scripts, [bridgeUrl]);
    const socket = FakeSocket.all[0];
    assert.equal(socket.url, `ws://127.0.0.1:4100/${capability}/_webui_ws_connect`);

    socket.open();
    await socket.onmessage({ data: frame(0xf5, Uint8Array.of(1)) });
    assert.equal(sdk.isConnected(), true);
    assert.equal(changes.at(-1), true);

    const api = sdk.bindings<{ add: [a: number, b: number] }>();
    const reply = api.add(1, 2);
    await tick();
    const sent = socket.sent.at(-1) as Uint8Array;
    assert.equal(sent[7], 0xf9);
    assert.deepEqual(
        new TextDecoder().decode(sent.subarray(8)).split("\0"),
        ["add", "1;1", "1", "2", ""],
    );
    const id = new DataView(sent.buffer, sent.byteOffset).getUint16(5, true);
    await socket.onmessage({ data: frame(0xf9, new TextEncoder().encode("3"), id) });
    assert.equal(await reply, "3");

    socket.readyState = 3;
    socket.onclose({ code: 1006 });
    assert.equal(sdk.isConnected(), false);
    assert.equal(changes.at(-1), false);
});

test("reloads reuse the stored bridge URL and hosted pages use their capability", async () => {
    const storage = new Map([["zig-webui:bridge-url", bridgeUrl]]);
    const reloaded = installBrowser("http://localhost:5173/app", storage);
    reloaded.serve.set(bridgeUrl, served);
    await (await loadSdk()).loadBridge();
    assert.deepEqual(reloaded.scripts, [bridgeUrl]);
    assert.deepEqual(reloaded.replaced, []);

    delete g.webui;
    delete g.__zigWebuiLoading;
    const hosted = installBrowser(`http://127.0.0.1:4100/${capability}/nested/page.html`);
    hosted.serve.set(bridgeUrl, served);
    await (await loadSdk()).loadBridge();
    assert.deepEqual(hosted.scripts, [bridgeUrl]);
});

test("pages without a bridge reject, and failed loads can be retried", async () => {
    installBrowser("http://localhost:5173/");
    const sdk = await loadSdk();
    await assert.rejects(sdk.loadBridge(), /not available/);
    await assert.rejects(sdk.call("anything"), /not available/);

    const env = installBrowser("http://localhost:5173/");
    const first = sdk.loadBridge("http://127.0.0.1:1/missing.js");
    const second = sdk.loadBridge("http://127.0.0.1:1/missing.js");
    await assert.rejects(first, /failed to load/);
    await assert.rejects(second, /failed to load/);
    assert.equal(env.scripts.length, 1);

    env.serve.set(bridgeUrl, served);
    await sdk.loadBridge(bridgeUrl);
    assert.deepEqual(env.scripts, ["http://127.0.0.1:1/missing.js", bridgeUrl]);
});

test("an included webui.js is adopted and its banner kept until state is observed", async () => {
    installBrowser("http://127.0.0.1:4100/");
    const bridge = fakeBridge(true);
    g.webui = bridge;
    const sdk = await loadSdk();
    assert.equal(await sdk.loadBridge(), bridge);
    assert.equal(sdk.isConnected(), true);
    assert.equal(bridge.hasCallback, false);

    assert.equal(await sdk.call("echo", "a", 2, true, 3n), "echo:a,2,true,3");
    let seen = 0;
    const unsubscribe = sdk.subscribe(() => seen++);
    assert.equal(bridge.hasCallback, true);
    bridge.emit(false);
    bridge.emit(false);
    assert.equal(sdk.isConnected(), false);
    assert.equal(seen, 1);
    unsubscribe();
    bridge.emit(true);
    assert.equal(seen, 1);
    assert.equal(sdk.isConnected(), true);
});
