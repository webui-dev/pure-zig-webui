// Minimal browser globals for SDK tests: location/history/sessionStorage, a
// script element whose load evaluates a source, and a WebSocket mock.
import { readFileSync } from "node:fs";
import { runInThisContext } from "node:vm";

export const bridgeSource = readFileSync(new URL("../../src/bridge.js", import.meta.url), "utf8");

export class FakeSocket {
    static OPEN = 1;
    static all: FakeSocket[] = [];
    readyState = 0;
    binaryType = "";
    sent: (Uint8Array | string)[] = [];
    onopen: () => void = () => {};
    onclose: (event?: { code?: number }) => void = () => {};
    onmessage: (event: { data: ArrayBuffer | string }) => unknown = () => {};
    url: string;
    constructor(url: string) {
        this.url = url;
        FakeSocket.all.push(this);
    }
    send(data: Uint8Array | string) {
        this.sent.push(data);
    }
    close() {
        this.readyState = 3;
    }
    open() {
        this.readyState = 1;
        this.onopen();
    }
}

export function frame(command: number, payload: Uint8Array, id = 0, token = 7): ArrayBuffer {
    const bytes = new Uint8Array(8 + payload.length);
    const view = new DataView(bytes.buffer);
    bytes[0] = 0xdd;
    view.setUint32(1, token, true);
    view.setUint16(5, id, true);
    bytes[7] = command;
    bytes.set(payload, 8);
    return bytes.buffer;
}

export type Environment = {
    href: string;
    replaced: string[];
    scripts: string[];
    storage: Map<string, string>;
    /** Source evaluated when an injected script with this URL loads. */
    serve: Map<string, string>;
};

export function installBrowser(href: string, storage = new Map<string, string>()): Environment {
    const env: Environment = { href, replaced: [], scripts: [], storage, serve: new Map() };
    const g = globalThis as Record<string, unknown>;
    const location = {
        get href() { return env.href; },
        get hash() { return new URL(env.href).hash; },
        get pathname() { return new URL(env.href).pathname; },
        get search() { return new URL(env.href).search; },
        get origin() { return new URL(env.href).origin; },
        get protocol() { return new URL(env.href).protocol; },
        get host() { return new URL(env.href).host; },
    };
    const document = {
        currentScript: null as { src: string } | null,
        body: { appendChild() {} },
        documentElement: { appendChild() {} },
        addEventListener() {},
        head: {
            appendChild(script: { src: string; onload(): void; onerror(): void }) {
                env.scripts.push(script.src);
                queueMicrotask(() => {
                    const source = env.serve.get(script.src);
                    if (source === undefined) return script.onerror();
                    document.currentScript = script;
                    try {
                        runInThisContext(source);
                    } finally {
                        document.currentScript = null;
                    }
                    script.onload();
                });
            },
        },
        createElement(tag: string) {
            if (tag !== "script") throw new Error(`unexpected element ${tag}`);
            return { src: "", async: false, onload() {}, onerror() {} };
        },
    };
    Object.assign(g, {
        location,
        document,
        history: {
            state: null,
            replaceState(_: unknown, __: string, url: string) {
                env.replaced.push(url);
                env.href = new URL(url, env.href).href;
            },
        },
        sessionStorage: {
            getItem: (key: string) => storage.get(key) ?? null,
            setItem: (key: string, value: string) => void storage.set(key, value),
        },
        WebSocket: FakeSocket,
        addEventListener() {},
    });
    return env;
}

export function fakeBridge(connected = false) {
    let callback: ((kind: 0 | 1) => void) | null = null;
    const calls: unknown[][] = [];
    const bridge = {
        event: { CONNECTED: 0, DISCONNECTED: 1 } as const,
        connected,
        isConnected: () => bridge.connected,
        call: async (name: string, ...args: unknown[]) => {
            calls.push([name, ...args]);
            return `${name}:${args.join(",")}`;
        },
        setLogging() {},
        encode: (data: string) => data,
        decode: (data: string) => data,
        setEventCallback(next: (kind: 0 | 1) => void) {
            callback = next;
        },
        isHighContrast: async () => false,
        allowNavigation() {},
        get hasCallback() {
            return callback !== null;
        },
        emit(value: boolean) {
            bridge.connected = value;
            callback?.(value ? 0 : 1);
        },
        calls,
    };
    return bridge;
}

export const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
