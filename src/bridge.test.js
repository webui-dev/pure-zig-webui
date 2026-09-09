const assert = require("node:assert/strict");
const test = require("node:test");
const { readFileSync } = require("node:fs");
const { runInNewContext } = require("node:vm");

const source = readFileSync(require.resolve("./bridge.js"), "utf8");
const encoder = new TextEncoder();
const decoder = new TextDecoder();

function frame(command, payload = new Uint8Array(), id = 0, token = 7) {
    const bytes = new Uint8Array(8 + payload.length);
    const view = new DataView(bytes.buffer);
    bytes[0] = 0xdd;
    view.setUint32(1, token, true);
    view.setUint16(5, id, true);
    bytes[7] = command;
    bytes.set(payload, 8);
    return bytes;
}

function isolatedCallBridge(options = {}) {
    let now = 0;
    let nextTimer = 0;
    const timers = new Map();
    const sockets = [];
    const listeners = new Map();
    const domListeners = new Map();
    const navigationListeners = new Map();
    const banners = [];
    const outcomes = [];
    const events = [];
    const addListener = (target, type, listener) => {
        if (!target.has(type)) target.set(type, []);
        target.get(type).push(listener);
    };
    class WebSocketMock {
        static OPEN = 1;
        constructor(url) {
            this.url = url;
            this.readyState = 0;
            this.sentPackets = [];
            this.sentIds = [];
            this.sendError = null;
            this.failAt = Infinity;
            sockets.push(this);
        }
        open() {
            this.readyState = 1;
            this.onopen();
        }
        send(bytes) {
            assert.equal(this.readyState, 1);
            if (this.sendError || this.sentPackets.length === this.failAt)
                throw this.sendError || new Error("simulated partial send failure");
            this.sentPackets.push(bytes);
            if (typeof bytes !== "string" && bytes[7] === 0xf9)
                this.sentIds.push(new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).getUint16(5, true));
        }
        close() {
            this.readyState = 3;
        }
        lose(code = 1006) {
            this.readyState = 3;
            this.onclose({ code });
        }
    }
    const root = {
        appendChild(element) { banners.push(element); },
    };
    const context = {
        WebSocket: WebSocketMock,
        TextEncoder,
        TextDecoder,
        Uint8Array,
        URL,
        console: { log() {} },
        btoa,
        atob,
        setTimeout(callback, delay) {
            const id = ++nextTimer;
            timers.set(id, { at: now + delay, callback });
            return id;
        },
        clearTimeout(id) { timers.delete(id); },
        addEventListener(type, listener) { addListener(listeners, type, listener); },
        document: {
            currentScript: options.script ? { src: options.script } : null,
            body: root,
            documentElement: root,
            addEventListener(type, listener) { addListener(domListeners, type, listener); },
            createElement(tag) {
                assert.equal(tag, "div");
                return {
                    style: {},
                    attributes: {},
                    setAttribute(name, value) { this.attributes[name] = value; },
                    set innerHTML(value) { assert.fail("warning must not parse HTML"); },
                    remove() { banners.splice(banners.indexOf(this), 1); },
                };
            },
        },
        location: { protocol: "http:", host: "localhost", href: "/" },
        close() { context.windowClosed = true; },
        __zigWebuiCapability: "test-capability",
        __zigWebuiToken: 7,
        __zigWebuiBindings: [...(options.events ? [""] : []), ...(options.bindings || [])],
    };
    if (options.navigation) context.navigation = {
        addEventListener(type, listener) { addListener(navigationListeners, type, listener); },
    };
    runInNewContext(source, context);
    if (options.callback) context.webui.setEventCallback(options.callback);
    const bridge = {
        context, sockets, timers, banners, listeners, domListeners, navigationListeners, outcomes, events,
        get socket() { return sockets.at(-1); },
        get webui() { return context.webui; },
        async tick(milliseconds) {
            const target = now + milliseconds;
            while (true) {
                const next = [...timers].filter(([, timer]) => timer.at <= target)
                    .sort((a, b) => a[1].at - b[1].at || a[0] - b[0])[0];
                if (!next) break;
                now = next[1].at;
                timers.delete(next[0]);
                next[1].callback();
                await Promise.resolve();
            }
            now = target;
            await Promise.resolve();
        },
        dispatch(type, value = {}) {
            for (const listener of listeners.get(type) || []) listener(value);
        },
        receive(command, payload, id = 0, socket = bridge.socket, token = 7) {
            return socket.onmessage({ data: frame(command, payload, id, token) });
        },
        async connect() {
            if (bridge.socket.readyState === 3) await bridge.tick(500);
            bridge.socket.open();
            await bridge.receive(0xf5, Uint8Array.of(1));
        },
        reply(id, value, socket = bridge.socket) {
            return bridge.receive(0xf9, encoder.encode(value), id, socket);
        },
        call(...args) {
            const outcome = { status: "pending" };
            outcomes.push(outcome);
            context.webui.call(...args).then(
                (value) => Object.assign(outcome, { status: "fulfilled", value }),
                (error) => Object.assign(outcome, { status: "rejected", error }),
            );
            return outcome;
        },
        async close() {
            bridge.socket.lose();
            await Promise.resolve();
            assert.equal(outcomes.filter((outcome) => outcome.status === "pending").length, 0);
        },
    };
    return bridge;
}

test("bridge authenticates each replacement and isolates pending calls and stale async results", async () => {
    const bridge = isolatedCallBridge();
    bridge.webui.setEventCallback((value) => bridge.events.push(value));
    const old = bridge.socket;
    old.open();
    assert.equal(bridge.webui.isConnected(), false);
    await assert.rejects(bridge.webui.call("early"));
    await bridge.receive(0xfd, encoder.encode("globalThis.early = true"));
    assert.equal(bridge.context.early, undefined);
    await bridge.receive(0xf5, Uint8Array.of(1));
    await bridge.receive(0xf5, Uint8Array.of(1));
    assert.deepEqual(bridge.events, [0]);
    const pending = bridge.call("pending");
    let release;
    bridge.context.delayed = new Promise((resolve) => { release = resolve; });
    const evaluation = bridge.receive(0xfe, encoder.encode("return await globalThis.delayed"), 91);
    old.lose();
    old.onclose({ code: 1006 });
    await Promise.resolve();
    assert.equal(pending.status, "rejected");
    assert.deepEqual(bridge.events, [0, 1]);
    await bridge.tick(499);
    assert.equal(bridge.sockets.length, 1);
    bridge.context.__zigWebuiCapability = "changed";
    bridge.context.__zigWebuiToken = 99;
    await bridge.tick(1);
    const replacement = bridge.socket;
    replacement.open();
    assert.equal(replacement.url, old.url);
    const auth = replacement.sentPackets[0];
    assert.equal(auth[7], 0xf5);
    assert.equal(new DataView(auth.buffer).getUint32(1, true), 7);
    assert.equal(decoder.decode(auth.subarray(8)), "test-capability");
    await bridge.receive(0xfd, encoder.encode("globalThis.early = true"));
    assert.equal(bridge.context.early, undefined);
    await bridge.receive(0xf5, Uint8Array.of(1));
    assert.deepEqual(bridge.events, [0, 1, 0]);
    const current = bridge.call("new");
    const id = replacement.sentIds.at(-1);
    await bridge.reply(id, "stale", old);
    assert.equal(current.status, "pending");
    const sends = replacement.sentPackets.length;
    release("old result");
    await evaluation;
    old.onopen();
    await bridge.receive(0xfa, undefined, 0, old);
    assert.equal(replacement.sentPackets.length, sends);
    assert.equal(bridge.webui.isConnected(), true);
    await bridge.reply(id, "current");
    assert.deepEqual(current, { status: "fulfilled", value: "current" });
    assert.equal(replacement.sentIds.length, 1, "lost calls are never replayed");
});

test("authentication denial, invalid tokens, protocol policy and backend close stop recovery", async () => {
    for (const reason of ["denied", "token", "close", 1002, 1003, 1007, 1008, 1009]) {
        const bridge = isolatedCallBridge();
        bridge.socket.open();
        if (reason === "denied") await bridge.receive(0xf5, Uint8Array.of(0));
        else if (reason === "token") await bridge.receive(0xf5, Uint8Array.of(1), 0, bridge.socket, 99);
        else {
            await bridge.receive(0xf5, Uint8Array.of(1));
            if (reason === "close") await bridge.receive(0xfa);
            else bridge.socket.lose(reason);
        }
        assert.equal(bridge.webui.isConnected(), false);
        assert.equal(bridge.socket.readyState, 3);
        assert.equal(bridge.timers.size, 0);
        assert.equal(bridge.banners.length, reason === "close" ? 0 : 1);
        if (reason !== "close") assert.equal(bridge.banners[0].attributes.role, "alert");
        bridge.dispatch("pagehide", { persisted: true });
        bridge.dispatch("pageshow", { persisted: true });
        await bridge.tick(60_000);
        assert.equal(bridge.sockets.length, 1);
        if (reason === "close") assert.equal(bridge.context.windowClosed, true);
    }
});

test("terminal rejection replaces recovery UI and notifies initially disconnected callbacks", async () => {
    const bridge = isolatedCallBridge();
    await bridge.connect();
    bridge.socket.lose();
    await bridge.tick(1000);
    assert.equal(bridge.banners[0].attributes.role, "status");
    bridge.socket.open();
    await bridge.receive(0xf5, Uint8Array.of(0));
    assert.equal(bridge.banners.length, 1);
    assert.equal(bridge.banners[0].attributes.role, "alert");
    assert.equal(bridge.timers.size, 0);

    const events = [];
    const custom = isolatedCallBridge({ callback: (event) => events.push(event) });
    custom.socket.open();
    await custom.receive(0xf5, Uint8Array.of(0));
    custom.socket.lose();
    assert.deepEqual(events, [1]);
    assert.equal(custom.banners.length, 0);
});

test("establishment and authentication share a five second deadline and warning", async () => {
    for (const open of [false, true]) {
        const bridge = isolatedCallBridge();
        if (open) bridge.socket.open();
        await bridge.tick(4999);
        assert.equal(bridge.banners.length, 0);
        assert.equal(bridge.socket.readyState, open ? 1 : 0);
        await bridge.tick(1);
        assert.equal(bridge.socket.readyState, 3);
        assert.equal(bridge.banners.length, 1);
        assert.equal(bridge.banners[0].attributes.role, "status");
        assert.equal(typeof bridge.banners[0].textContent, "string");
        await bridge.tick(500);
        bridge.socket.open();
        assert.equal(bridge.banners.length, 1);
        await bridge.receive(0xf5, Uint8Array.of(1));
        assert.equal(bridge.banners.length, 0);
        assert.equal(bridge.webui.isConnected(), true);
    }
});

test("heartbeat requires pong within ten seconds and cleans old session deadlines", async () => {
    const bridge = isolatedCallBridge();
    await bridge.connect();
    await bridge.tick(19_999);
    assert.equal(bridge.socket.sentPackets.includes("ping"), false);
    await bridge.tick(1);
    assert.equal(bridge.socket.sentPackets.at(-1), "ping");
    await bridge.tick(9999);
    await bridge.socket.onmessage({ data: "pong" });
    await bridge.tick(10_001);
    assert.equal(bridge.socket.sentPackets.filter((value) => value === "ping").length, 2);
    const old = bridge.socket;
    await bridge.tick(10_000);
    assert.equal(bridge.webui.isConnected(), false);
    assert.equal(old.readyState, 3);
    await bridge.tick(500);
    await bridge.connect();
    await old.onmessage({ data: "pong" });
    await bridge.tick(20_000);
    await bridge.tick(10_000);
    assert.equal(bridge.webui.isConnected(), false, "old pong cannot satisfy the new session");
    bridge.dispatch("pagehide");
    assert.equal(bridge.timers.size, 0);
});

test("recoverable loss warning waits one second and custom callbacks own connection UI", async () => {
    const bridge = isolatedCallBridge();
    await bridge.connect();
    bridge.socket.lose();
    await bridge.tick(999);
    assert.equal(bridge.banners.length, 0);
    await bridge.tick(1);
    assert.equal(bridge.banners.length, 1);
    bridge.socket.open();
    assert.equal(bridge.banners.length, 1);
    await bridge.receive(0xf5, Uint8Array.of(1));
    assert.equal(bridge.banners.length, 0);
    bridge.socket.lose();
    await bridge.tick(1000);
    assert.equal(bridge.banners.length, 1);
    bridge.webui.setEventCallback((value) => {
        bridge.events.push(value);
        throw new Error("callback failure");
    });
    assert.equal(bridge.banners.length, 0);
    bridge.socket.open();
    await bridge.receive(0xf5, Uint8Array.of(1));
    await bridge.receive(0xf5, Uint8Array.of(1));
    bridge.socket.lose();
    await bridge.tick(1000);
    assert.equal(bridge.banners.length, 0);
    assert.deepEqual(bridge.events, [0, 1]);
    bridge.socket.open();
    await bridge.receive(0xf5, Uint8Array.of(1));
    assert.equal(bridge.webui.isConnected(), true);
    assert.deepEqual(bridge.events, [0, 1, 0]);
});

test("pagehide stops all work, BFCache resumes once, and same-document navigation remains live", async () => {
    const bridge = isolatedCallBridge({ events: true, navigation: true });
    await bridge.connect();
    await bridge.receive(0xfb, encoder.encode("/#section"));
    assert.equal(bridge.context.location.href, "/#section");
    const nav = bridge.navigationListeners.get("navigate")[0];
    nav({ cancelable: true, destination: { url: "/#section" }, preventDefault() { assert.fail("backend navigation intercepted"); } });
    assert.equal(bridge.webui.isConnected(), true);
    await bridge.tick(20_000);
    assert.equal(bridge.socket.sentPackets.at(-1), "ping");
    const pending = bridge.call("unloading");
    const old = bridge.socket;
    bridge.dispatch("pagehide", { persisted: true });
    await Promise.resolve();
    assert.equal(pending.status, "rejected");
    assert.equal(bridge.timers.size, 0);
    await bridge.tick(60_000);
    assert.equal(bridge.sockets.length, 1);
    bridge.dispatch("pageshow", { persisted: false });
    assert.equal(bridge.sockets.length, 1);
    bridge.dispatch("pageshow", { persisted: true });
    bridge.dispatch("pageshow", { persisted: true });
    assert.equal(bridge.sockets.length, 2);
    old.onopen();
    await bridge.receive(0xf5, Uint8Array.of(1), 0, old);
    assert.equal(bridge.webui.isConnected(), false);
    await bridge.connect();
    assert.equal(bridge.webui.isConnected(), true);
    assert.equal(bridge.listeners.get("pagehide").length, 1);
    assert.equal(bridge.listeners.get("pageshow").length, 1);
    assert.equal(bridge.domListeners.get("click").length, 1);
    assert.equal(bridge.navigationListeners.get("navigate").length, 1);
    bridge.dispatch("pagehide");
    assert.equal(bridge.timers.size, 0);
});

test("commands, public helpers, external origins and large packets preserve behavior", async () => {
    const bridge = isolatedCallBridge({ events: true, script: "https://bridge.example:9443/capability/webui.js" });
    assert.equal(bridge.socket.url, "wss://bridge.example:9443/test-capability/_webui_ws_connect");
    assert.equal(bridge.webui.encode("Zig WebUI"), "WmlnIFdlYlVJ");
    assert.equal(bridge.webui.decode("WmlnIFdlYlVJ"), "Zig WebUI");
    assert.throws(() => bridge.webui.setEventCallback(null));
    for (const active of ["(forced-colors: active)", "(prefers-contrast: more)"]) {
        bridge.context.matchMedia = (query) => ({ matches: query === active });
        assert.equal(await bridge.webui.isHighContrast(), true);
    }
    delete bridge.context.matchMedia;
    assert.equal(await bridge.webui.isHighContrast(), false);
    bridge.webui.setLogging(true);
    bridge.webui.setLogging(false);
    await bridge.connect();
    const largeArgument = new Uint8Array(65_500).fill(0x61);
    const before = bridge.socket.sentPackets.length;
    const large = bridge.webui.call("large", largeArgument);
    const [pre, ...chunks] = bridge.socket.sentPackets.slice(before);
    assert.equal(pre[7], 0xf6);
    assert.equal(chunks[0].length, 65_500);
    const rebuilt = Buffer.concat(chunks);
    assert.equal(rebuilt.length, Number(decoder.decode(pre.subarray(8, pre.length - 1))));
    assert.equal(rebuilt[7], 0xf9);
    assert.deepEqual(new Uint8Array(rebuilt.subarray(-largeArgument.length - 1, -1)), largeArgument);
    await bridge.reply(rebuilt.readUInt16LE(5), "large-ok");
    assert.equal(await large, "large-ok");
    const sends = bridge.socket.sentPackets.length;
    await bridge.receive(0xfd, encoder.encode("globalThis.quickResult = 42"));
    assert.equal(bridge.context.quickResult, 42);
    assert.equal(bridge.socket.sentPackets.length, sends);
    await bridge.receive(0xfe, encoder.encode("return 'result'"), 42);
    let response = bridge.socket.sentPackets.at(-1);
    assert.equal(response[8], 0);
    assert.equal(decoder.decode(response.subarray(9, -1)), "result");
    await bridge.receive(0xfe, encoder.encode("throw new Error('failure')"), 43);
    response = bridge.socket.sentPackets.at(-1);
    assert.equal(response[8], 1);
    let raw;
    bridge.context.receiveRaw = (data) => { raw = [...data]; };
    await bridge.receive(0xf8, new Uint8Array([...encoder.encode("receiveRaw"), 0, 0, 1, 255]));
    assert.deepEqual(raw, [0, 1, 255]);
    const click = bridge.domListeners.get("click")[0];
    click({ target: { closest: (selector) => selector === "[id]" ? { id: "run" } : null } });
    assert.equal(bridge.socket.sentPackets.at(-1)[7], 0xfc);
    assert.equal(decoder.decode(bridge.socket.sentPackets.at(-1).subarray(8)), "run");
    let prevented = false;
    const link = { target: { closest: (selector) => selector === "a[href]" ? { href: "/next" } : null }, preventDefault() { prevented = true; } };
    click(link);
    assert.equal(prevented, true);
    assert.equal(bridge.socket.sentPackets.at(-1)[7], 0xfb);
    bridge.webui.allowNavigation(true);
    prevented = false;
    const allowedSends = bridge.socket.sentPackets.length;
    click(link);
    assert.equal(prevented, false);
    assert.equal(bridge.socket.sentPackets.length, allowedSends);
    const binding = isolatedCallBridge({ bindings: ["dynamic-binding"] });
    await binding.connect();
    binding.domListeners.get("click")[0]({ target: { closest: () => ({ id: "dynamic-binding" }) } });
    assert.equal(decoder.decode(binding.socket.sentPackets.at(-1).subarray(8)), "dynamic-binding");
});

test("partial MULTI send failure retires transport and rejects every pending call", async () => {
    const bridge = isolatedCallBridge();
    await bridge.connect();
    const old = bridge.socket;
    const pending = bridge.call("pending");
    old.failAt = old.sentPackets.length + 2;
    const failed = bridge.call("large", new Uint8Array(140_000));
    await Promise.resolve();
    assert.equal(pending.status, "rejected");
    assert.equal(failed.status, "rejected");
    assert.equal(old.readyState, 3);
    await bridge.connect();
    assert.equal(bridge.socket.sentPackets.length, 1, "partial packet must never continue on replacement");
    const recovered = bridge.call("recovered");
    await bridge.reply(bridge.socket.sentIds.at(-1), "ok");
    assert.deepEqual(recovered, { status: "fulfilled", value: "ok" });
});

test("pending call IDs survive wrap, exhaustion, reuse, send failure and disconnect", async () => {
    const bridge = isolatedCallBridge();
    let socket = bridge.socket;
    await bridge.connect();
    try {
        const oldest = bridge.call("oldest");
        for (let id = 2; id < 0xffff; id++) bridge.call("pending");
        await bridge.reply(2, "released-before-wrap");
        bridge.call("last-before-wrap");
        const wrapped = bridge.call("wrapped");
        assert.equal(socket.sentIds.at(-1), 2);
        assert.equal(oldest.status, "pending");
        assert.deepEqual(new Set(socket.sentIds.slice(0, 0xffff)), new Set(Array.from({ length: 0xffff }, (_, index) => index + 1)));
        const sendsAtCapacity = socket.sentIds.length;
        const overflow = bridge.call("overflow");
        await Promise.resolve();
        assert.equal(overflow.status, "rejected");
        assert.equal(socket.sentIds.length, sendsAtCapacity);
        assert.equal(oldest.status, "pending");
        assert.equal(wrapped.status, "pending");
        await bridge.reply(1, "oldest-response");
        assert.deepEqual(oldest, { status: "fulfilled", value: "oldest-response" });
        const reused = bridge.call("reuse-oldest-slot");
        assert.equal(socket.sentIds.at(-1), 1);
        await bridge.reply(2, "wrapped-response");
        assert.deepEqual(wrapped, { status: "fulfilled", value: "wrapped-response" });
        bridge.call("refill-wrapped-slot");
        await bridge.reply(32768, "release-for-send-failure");
        const sendError = new Error("simulated send failure");
        socket.sendError = sendError;
        const failedSend = bridge.call("failed-send");
        await Promise.resolve();
        assert.equal(failedSend.status, "rejected");
        assert.equal(failedSend.error, sendError);
        assert.equal(reused.status, "rejected");
        const offline = bridge.call("offline");
        await Promise.resolve();
        assert.equal(offline.status, "rejected");
        await bridge.connect();
        socket = bridge.socket;
        const reconnected = bridge.call("reconnected");
        for (let count = 1; count < 0xffff; count++) bridge.call("refill");
        assert.equal(socket.sentIds.length, 0xffff);
        assert.equal(new Set(socket.sentIds).size, 0xffff);
        const reconnectedOverflow = bridge.call("reconnected-overflow");
        await Promise.resolve();
        assert.equal(reconnectedOverflow.status, "rejected");
        assert.equal(socket.sentIds.length, 0xffff);
        await bridge.reply(socket.sentIds[0], "reconnected-response");
        assert.deepEqual(reconnected, { status: "fulfilled", value: "reconnected-response" });
    } finally {
        await bridge.close();
    }
});

test("argument conversion can reenter calls at capacity or disconnect without leaking slots", async () => {
    const bridge = isolatedCallBridge();
    let socket = bridge.socket;
    await bridge.connect();
    try {
        const oldest = bridge.call("oldest");
        for (let count = 1; count < 0xfffe; count++) bridge.call("pending");
        let nested;
        const outer = bridge.call("outer", {
            toString() {
                nested = bridge.call("nested");
                return "argument";
            },
        });
        await Promise.resolve();
        assert.equal(outer.status, "rejected");
        assert.equal(nested.status, "pending");
        assert.equal(socket.sentIds.length, 0xffff);
        assert.equal(new Set(socket.sentIds).size, 0xffff);
        await bridge.reply(socket.sentIds.at(-1), "nested-response");
        assert.deepEqual(nested, { status: "fulfilled", value: "nested-response" });
        await bridge.reply(1, "oldest-response");
        assert.deepEqual(oldest, { status: "fulfilled", value: "oldest-response" });
        await bridge.close();
        await bridge.connect();
        socket = bridge.socket;
        const sendsBeforeDisconnect = socket.sentIds.length;
        const disconnected = bridge.call("disconnect-during-conversion", {
            toString() {
                socket.lose();
                return "argument";
            },
        });
        await Promise.resolve();
        assert.equal(disconnected.status, "rejected");
        assert.equal(socket.sentIds.length, sendsBeforeDisconnect);
    } finally {
        await bridge.close();
    }
});

test("ADD_ID activates a connected empty page and keeps core and prototype methods intact", async () => {
    const bridge = isolatedCallBridge();
    await bridge.connect();
    const click = (id) => bridge.domListeners.get("click")[0]({
        target: { closest: (selector) => selector === "[id]" ? { id } : null },
    });
    const initialSends = bridge.socket.sentPackets.length;
    click("later");
    assert.equal(bridge.socket.sentPackets.length, initialSends);
    await bridge.receive(0xf7, encoder.encode("later\0"));
    await bridge.receive(0xf7, encoder.encode("later"));
    click("later");
    assert.equal(bridge.socket.sentPackets.length, initialSends + 1);
    assert.equal(bridge.socket.sentPackets.at(-1)[7], 0xfc);
    click("unregistered");
    assert.equal(bridge.socket.sentPackets.length, initialSends + 1);
    const result = bridge.webui.later("argument");
    const request = bridge.socket.sentPackets.at(-1);
    assert.equal(decoder.decode(request.subarray(8)), "later\0" + "8\0argument\0");
    await bridge.reply(bridge.socket.sentIds.at(-1), "runtime");
    assert.equal(await result, "runtime");

    for (const name of ["call", "allowNavigation", "event", "__proto__", "constructor", "toString", "__webui_core_api__"]) {
        const before = bridge.webui[name];
        await bridge.receive(0xf7, encoder.encode(name));
        assert.equal(bridge.webui[name], before);
        const fallback = bridge.webui.call(name);
        await bridge.reply(bridge.socket.sentIds.at(-1), name);
        assert.equal(await fallback, name);
    }
    await bridge.receive(0xf7, Uint8Array.of(0xff));
    await bridge.receive(0xf7, encoder.encode("bad\0name"));
    assert.equal(Object.hasOwn(bridge.webui, "\ufffd"), false);
    assert.equal(Object.hasOwn(bridge.webui, "bad\0name"), false);
    bridge.dispatch("pagehide");
});

test("runtime all-events registration enables navigation without clobbering explicit policy", async () => {
    for (const navigation of [false, true]) {
        const bridge = isolatedCallBridge({ navigation });
        await bridge.connect();
        let prevented = 0;
        function navigate() {
            if (navigation) {
                bridge.navigationListeners.get("navigate")[0]({
                    cancelable: true,
                    destination: { url: "/next" },
                    preventDefault() { prevented++; },
                });
            } else {
                bridge.domListeners.get("click")[0]({
                    target: { closest: (selector) => selector === "a[href]" ? { href: "/next" } : null },
                    preventDefault() { prevented++; },
                });
            }
        }
        navigate();
        assert.equal(prevented, 0);
        await bridge.receive(0xf7, new Uint8Array());
        navigate();
        assert.equal(prevented, 1);
        assert.equal(bridge.socket.sentPackets.at(-1)[7], 0xfb);
        bridge.webui.allowNavigation(true);
        await bridge.receive(0xf7, Uint8Array.of(0));
        navigate();
        assert.equal(prevented, 1);
        bridge.socket.lose();
        await bridge.connect();
        await bridge.receive(0xf7, new Uint8Array());
        navigate();
        assert.equal(prevented, 1);
        bridge.webui.allowNavigation(false);
        navigate();
        assert.equal(prevented, 2);
        bridge.dispatch("pagehide");
    }
    const explicit = isolatedCallBridge();
    await explicit.connect();
    explicit.webui.allowNavigation(true);
    await explicit.receive(0xf7, new Uint8Array());
    explicit.domListeners.get("click")[0]({
        target: { closest: () => ({ href: "/allowed" }) },
        preventDefault() { assert.fail("explicit policy was replaced"); },
    });
    explicit.dispatch("pagehide");
});

test("authentication replay exposes convenience bindings before CONNECTED and isolates stale sessions", async () => {
    const name = "quoted\"\\\n雪,</script>";
    const bridge = isolatedCallBridge({ bindings: [name] });
    assert.equal(typeof bridge.webui[name], "function");
    bridge.socket.open();
    await bridge.receive(0xf7, encoder.encode("first"));
    let connectedCalls = 0;
    bridge.webui.setEventCallback((kind) => {
        if (kind === 0) {
            assert.equal(typeof bridge.webui.first, "function");
            if (connectedCalls++) assert.equal(typeof bridge.webui.offlineAdded, "function");
        }
    });
    await bridge.receive(0xf5, Uint8Array.of(1));
    const old = bridge.socket;
    old.lose();
    await bridge.tick(500);
    bridge.socket.open();
    await bridge.receive(0xf7, encoder.encode("stale"), 0, old);
    assert.equal(bridge.webui.stale, undefined);
    await bridge.receive(0xf7, encoder.encode("first"));
    await bridge.receive(0xf7, encoder.encode("offlineAdded"));
    await bridge.receive(0xf5, Uint8Array.of(1));
    assert.equal(connectedCalls, 2);
    const pending = bridge.webui.offlineAdded();
    await bridge.reply(bridge.socket.sentIds.at(-1), "replayed");
    assert.equal(await pending, "replayed");
    assert.equal(bridge.domListeners.get("click").length, 1);
    bridge.dispatch("pagehide");
});

test("native backend close requests preserve the bridge when vetoed", async () => {
    const bridge = isolatedCallBridge();
    await bridge.connect();
    let requests = 0;
    bridge.context.__zigWebuiNativeClose = () => { requests += 1; };
    await bridge.receive(0xfa);
    assert.equal(requests, 1);
    const call = bridge.call("still-live");
    await bridge.reply(bridge.socket.sentIds.at(-1), "veto preserved connection");
    assert.deepEqual(call, { status: "fulfilled", value: "veto preserved connection" });
    bridge.dispatch("pagehide");
    assert.equal(bridge.webui.isConnected(), false);
    assert.equal(bridge.timers.size, 0);
    await bridge.tick(60_000);
    assert.equal(bridge.sockets.length, 1);
});
