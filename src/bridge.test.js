const assert = require("node:assert/strict");
const test = require("node:test");

test("bridge handles commands and external script origins", async () => {
    class WebSocketMock {
        static instance;

        constructor(url) {
            this.url = url;
            this.closed = false;
            this.sent = undefined;
            this.sentPackets = [];
            this.sendCount = 0;
            WebSocketMock.instance = this;
        }

        close() {
            this.closed = true;
        }

        send(data) {
            this.sent = data;
            this.sentPackets.push(data);
            this.sendCount += 1;
        }
    }

    const encoder = new TextEncoder();
    const frame = (command, payload = new Uint8Array(), id = 0) => {
        const bytes = new Uint8Array(8 + payload.length);
        const view = new DataView(bytes.buffer);
        bytes[0] = 0xdd;
        view.setUint16(5, id, true);
        bytes[7] = command;
        bytes.set(payload, 8);
        return bytes;
    };

    let windowClosed = false;
    let received;
    let clickListener;
    const bridgeEvents = [];
    const logs = [];
    const originalLog = console.log;
    console.log = (...args) => logs.push(args.join(" "));
    globalThis.WebSocket = WebSocketMock;
    globalThis.__zigWebuiCapability = "0123456789abcdef0123456789abcdef";
    globalThis.__zigWebuiEvents = true;
    globalThis.__zigWebuiDomBindings = false;
    globalThis.__zigWebuiToken = 7;
    globalThis.document = {
        addEventListener(type, listener) {
            if (type === "click") clickListener = listener;
        },
    };
    globalThis.location = {
        protocol: "http:",
        host: "localhost",
        href: "/",
    };
    globalThis.close = () => {
        windowClosed = true;
    };
    globalThis.matchMedia = (query) => ({
        matches: query === "(forced-colors: active)",
    });
    globalThis.receiveRaw = (data) => {
        received = [...data];
    };

    try {
        require("./bridge.js");
        assert.deepEqual(globalThis.webui.event, {
            CONNECTED: 0,
            DISCONNECTED: 1,
        });
        globalThis.webui.setEventCallback((event) => bridgeEvents.push(event));
        assert.throws(
            () => globalThis.webui.setEventCallback(null),
            /must be a function/,
        );
        assert.equal(globalThis.webui.encode("Zig WebUI"), "WmlnIFdlYlVJ");
        assert.equal(globalThis.webui.decode("WmlnIFdlYlVJ"), "Zig WebUI");
        assert.equal(await globalThis.webui.isHighContrast(), true);
        globalThis.matchMedia = (query) => ({
            matches: query === "(prefers-contrast: more)",
        });
        assert.equal(await globalThis.webui.isHighContrast(), true);
        globalThis.matchMedia = () => ({ matches: false });
        assert.equal(await globalThis.webui.isHighContrast(), false);
        delete globalThis.matchMedia;
        assert.equal(await globalThis.webui.isHighContrast(), false);
        globalThis.webui.setLogging(true);
        const socket = WebSocketMock.instance;
        assert.equal(
            socket.url,
            "ws://localhost/0123456789abcdef0123456789abcdef/_webui_ws_connect",
        );
        socket.onopen();
        assert.equal(
            new TextDecoder().decode(new Uint8Array(socket.sent).subarray(8)),
            globalThis.__zigWebuiCapability,
        );
        await socket.onmessage({
            data: frame(0xf5, Uint8Array.of(1)),
        });
        await socket.onmessage({
            data: frame(0xf5, Uint8Array.of(1)),
        });
        assert.deepEqual(bridgeEvents, [globalThis.webui.event.CONNECTED]);
        assert(logs.includes("WebUI -> Log Enabled."));
        assert(logs.includes("WebUI -> Connected"));
        const largeArgument = new Uint8Array(65_500).fill(0x61);
        const sendsBeforeMulti = socket.sentPackets.length;
        const largeCall = globalThis.webui.call("large", largeArgument);
        const multiPackets = socket.sentPackets.slice(sendsBeforeMulti);
        assert.equal(multiPackets.length, 3);
        const prePacket = new Uint8Array(multiPackets[0]);
        assert.equal(prePacket[7], 0xf6);
        assert.equal(prePacket.at(-1), 0);
        const announcedLength = Number(
            new TextDecoder().decode(prePacket.subarray(8, prePacket.length - 1)),
        );
        const chunks = multiPackets.slice(1).map((data) => new Uint8Array(data));
        assert.equal(chunks[0].length, 65_500);
        const rebuilt = new Uint8Array(
            chunks.reduce((total, chunk) => total + chunk.length, 0),
        );
        let rebuiltAt = 0;
        for (const chunk of chunks) {
            rebuilt.set(chunk, rebuiltAt);
            rebuiltAt += chunk.length;
        }
        assert.equal(rebuilt.length, announcedLength);
        assert.equal(rebuilt[7], 0xf9);
        assert.deepEqual(
            rebuilt.subarray(
                rebuilt.length - largeArgument.length - 1,
                rebuilt.length - 1,
            ),
            largeArgument,
        );
        const largeCallId = new DataView(rebuilt.buffer).getUint16(5, true);
        await socket.onmessage({
            data: frame(0xf9, encoder.encode("large-ok"), largeCallId),
        });
        assert.equal(await largeCall, "large-ok");

        const sendsBeforeQuick = socket.sendCount;
        await socket.onmessage({
            data: frame(
                0xfd,
                encoder.encode("globalThis.quickResult = 42"),
            ),
        });
        assert.equal(globalThis.quickResult, 42);
        assert.equal(socket.sendCount, sendsBeforeQuick);

        const button = { id: "run" };
        clickListener({
            target: {
                closest(selector) {
                    return selector === "[id]" ? button : null;
                },
            },
        });
        let eventPacket = new Uint8Array(socket.sent);
        assert.equal(eventPacket[7], 0xfc);
        assert.equal(
            new TextDecoder().decode(eventPacket.subarray(8)),
            "run",
        );

        const anonymous = { id: "" };
        const sendsBeforeEmptyClick = socket.sendCount;
        clickListener({
            target: {
                closest(selector) {
                    return selector === "[id]" ? anonymous : null;
                },
            },
        });
        assert.equal(socket.sendCount, sendsBeforeEmptyClick);

        let prevented = false;
        const link = { href: "http://localhost/next" };
        clickListener({
            target: {
                closest(selector) {
                    return selector === "a[href]" ? link : null;
                },
            },
            preventDefault() {
                prevented = true;
            },
        });
        eventPacket = new Uint8Array(socket.sent);
        assert.equal(prevented, true);
        assert.equal(eventPacket[7], 0xfb);
        assert.equal(
            new TextDecoder().decode(eventPacket.subarray(8)),
            link.href,
        );
        globalThis.webui.allowNavigation(true);
        prevented = false;
        const sendsBeforeAllowedLink = socket.sendCount;
        clickListener({
            target: {
                closest(selector) {
                    return selector === "a[href]" ? link : null;
                },
            },
            preventDefault() {
                prevented = true;
            },
        });
        assert.equal(prevented, false);
        assert.equal(socket.sendCount, sendsBeforeAllowedLink);
        globalThis.webui.allowNavigation(false);

        await socket.onmessage({
            data: frame(0xfb, encoder.encode("/next")),
        });
        assert.equal(globalThis.location.href, "/next");

        const name = encoder.encode("receiveRaw");
        const raw = new Uint8Array(name.length + 4);
        raw.set(name);
        raw.set([0, 0, 1, 255], name.length);
        await socket.onmessage({ data: frame(0xf8, raw) });
        assert.deepEqual(received, [0, 1, 255]);

        await socket.onmessage({ data: frame(0xfa) });
        assert.equal(socket.closed, true);
        assert.equal(windowClosed, true);
        socket.onclose();
        socket.onclose();
        assert.deepEqual(bridgeEvents, [
            globalThis.webui.event.CONNECTED,
            globalThis.webui.event.DISCONNECTED,
        ]);
        assert(logs.includes("WebUI -> Disconnected"));
        globalThis.webui.setLogging(false);
        assert(logs.includes("WebUI -> Log Disabled."));

        let navigationListener;
        globalThis.navigation = {
            addEventListener(type, listener) {
                if (type === "navigate") navigationListener = listener;
            },
        };
        globalThis.document.currentScript = {
            src: "https://bridge.example:9443/capability/webui.js",
        };
        delete globalThis.webui;
        delete require.cache[require.resolve("./bridge.js")];
        require("./bridge.js");
        const navigationSocket = WebSocketMock.instance;
        assert.equal(
            navigationSocket.url,
            "wss://bridge.example:9443/0123456789abcdef0123456789abcdef/_webui_ws_connect",
        );
        navigationSocket.onopen();
        await navigationSocket.onmessage({
            data: frame(0xf5, Uint8Array.of(1)),
        });
        prevented = false;
        navigationListener({
            cancelable: true,
            destination: { url: "http://localhost/history" },
            preventDefault() {
                prevented = true;
            },
        });
        eventPacket = new Uint8Array(navigationSocket.sent);
        assert.equal(prevented, true);
        assert.equal(eventPacket[7], 0xfb);
        assert.equal(
            new TextDecoder().decode(eventPacket.subarray(8)),
            "http://localhost/history",
        );

        // Backend-initiated navigation must bypass the navigate listener
        // instead of bouncing back to Zig as a navigation event.
        await navigationSocket.onmessage({
            data: frame(0xfb, encoder.encode("http://localhost/backend")),
        });
        assert.equal(globalThis.location.href, "http://localhost/backend");
        prevented = false;
        const sendsAfterBackendNavigation = navigationSocket.sendCount;
        navigationListener({
            cancelable: true,
            destination: { url: "http://localhost/backend" },
            preventDefault() {
                prevented = true;
            },
        });
        assert.equal(prevented, false);
        assert.equal(
            navigationSocket.sendCount,
            sendsAfterBackendNavigation,
        );
        globalThis.webui.allowNavigation(false);
        globalThis.webui.allowNavigation(true);
        prevented = false;
        const sendsBeforeAllowedNavigation = navigationSocket.sendCount;
        navigationListener({
            cancelable: true,
            destination: { url: "http://localhost/allowed" },
            preventDefault() {
                prevented = true;
            },
        });
        assert.equal(prevented, false);
        assert.equal(
            navigationSocket.sendCount,
            sendsBeforeAllowedNavigation,
        );

        delete globalThis.navigation;
        globalThis.__zigWebuiEvents = false;
        globalThis.__zigWebuiDomBindings = true;
        clickListener = undefined;
        delete globalThis.webui;
        delete require.cache[require.resolve("./bridge.js")];
        require("./bridge.js");
        const bindingSocket = WebSocketMock.instance;
        bindingSocket.onopen();
        await bindingSocket.onmessage({
            data: frame(0xf5, Uint8Array.of(1)),
        });
        assert.equal(typeof clickListener, "function");

        const dynamicButton = { id: "dynamic-binding" };
        clickListener({
            target: {
                closest(selector) {
                    return selector === "[id]" ? dynamicButton : null;
                },
            },
        });
        eventPacket = new Uint8Array(bindingSocket.sent);
        assert.equal(eventPacket[7], 0xfc);
        assert.equal(
            new TextDecoder().decode(eventPacket.subarray(8)),
            dynamicButton.id,
        );

        prevented = false;
        const sendsBeforeLink = bindingSocket.sendCount;
        clickListener({
            target: {
                closest() {
                    return null;
                },
            },
            preventDefault() {
                prevented = true;
            },
        });
        assert.equal(prevented, false);
        assert.equal(bindingSocket.sendCount, sendsBeforeLink);
    } finally {
        console.log = originalLog;
        delete globalThis.WebSocket;
        delete globalThis.document;
        delete globalThis.location;
        delete globalThis.matchMedia;
        delete globalThis.navigation;
        delete globalThis.close;
        delete globalThis.receiveRaw;
        delete globalThis.quickResult;
        delete globalThis.webui;
        delete globalThis.__zigWebuiCapability;
        delete globalThis.__zigWebuiDomBindings;
        delete globalThis.__zigWebuiEvents;
        delete globalThis.__zigWebuiToken;
    }
});
