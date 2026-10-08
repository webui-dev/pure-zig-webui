/** Values the bridge can send as call arguments. */
export type CallArgument = string | number | boolean | bigint | Uint8Array;

/** The browser-side `webui` object installed by `webui.js`. */
export interface WebuiBridge {
    readonly event: { readonly CONNECTED: 0; readonly DISCONNECTED: 1 };
    isConnected(): boolean;
    call(name: string, ...args: CallArgument[]): Promise<string>;
    setLogging(status: boolean): void;
    encode(data: string): string;
    decode(data: string): string;
    setEventCallback(callback: (kind: 0 | 1) => void): void;
    isHighContrast(): Promise<boolean>;
    allowNavigation(status: boolean): void;
}

/** Binding names mapped to their argument tuples. */
export type BindingMap = Record<string, CallArgument[]>;

/** Typed functions for each binding; Zig replies are always strings. */
export type Bindings<T extends BindingMap> = {
    readonly [K in keyof T & string]: (...args: T[K]) => Promise<string>;
};

/** Location fragment key that `Content.dev_server` windows open with. */
export const bridgeFragmentKey = "webui-bridge";

type Global = typeof globalThis & {
    webui?: WebuiBridge;
    __zigWebuiLoading?: Promise<WebuiBridge>;
};

const global = globalThis as Global;
const storageKey = "zig-webui:bridge-url";
const capabilityPath = /^\/([0-9a-f]{32})\//;
const listeners = new Set<() => void>();
let bridge: WebuiBridge | null = global.webui ?? null;
let connected = bridge?.isConnected() ?? false;
let watching = false;

function readStorage(): string | null {
    try {
        return global.sessionStorage?.getItem(storageKey) ?? null;
    } catch {
        return null;
    }
}

function writeStorage(url: string) {
    try {
        global.sessionStorage?.setItem(storageKey, url);
    } catch {}
}

/**
 * Take the bridge URL a `Content.dev_server` window was opened with. The
 * fragment is removed from the address bar before routers read it and kept
 * in session storage so development reloads reconnect to the same window.
 */
export function takeBridgeUrl(): string | null {
    const location = global.location;
    if (!location) return readStorage();
    const fragment = new URLSearchParams(location.hash.slice(1));
    const url = fragment.get(bridgeFragmentKey);
    if (url === null) return readStorage();
    fragment.delete(bridgeFragmentKey);
    const rest = fragment.toString();
    try {
        global.history?.replaceState(
            global.history.state,
            "",
            `${location.pathname}${location.search}${rest ? `#${rest}` : ""}`,
        );
    } catch {}
    writeStorage(url);
    return url;
}

function hostedBridgeUrl(): string | null {
    const location = global.location;
    const match = location && capabilityPath.exec(location.pathname);
    return match ? `${location.origin}/${match[1]}/webui.js` : null;
}

function notify() {
    for (const listener of listeners) listener();
}

function setConnected(value: boolean) {
    if (connected === value) return;
    connected = value;
    notify();
}

function adopt(loaded: WebuiBridge): WebuiBridge {
    if (bridge === loaded) return loaded;
    bridge = loaded;
    connected = loaded.isConnected();
    if (listeners.size > 0) watch(loaded);
    notify();
    return loaded;
}

// Installing an event callback replaces the bridge's built-in connection
// banner, so it is only taken over once something renders connection state.
function watch(loaded: WebuiBridge) {
    if (watching) return;
    watching = true;
    loaded.setEventCallback((kind) => setConnected(kind === loaded.event.CONNECTED));
    setConnected(loaded.isConnected());
}

function inject(url: string): Promise<WebuiBridge> {
    return new Promise((resolve, reject) => {
        const script = document.createElement("script");
        script.src = url;
        script.async = true;
        script.onload = () => {
            if (global.webui) resolve(global.webui);
            else reject(new Error(`zig-webui bridge at ${url} did not install webui`));
        };
        script.onerror = () => reject(new Error(`zig-webui bridge failed to load from ${url}`));
        document.head.appendChild(script);
    });
}

/**
 * Resolve the bridge, loading it when the page did not include `webui.js`.
 * The URL is taken from `url`, then the `dev_server` fragment or session
 * storage, then the capability path of a page served by zig-webui.
 * Concurrent and repeated calls share one script, also across hot reloads.
 */
export function loadBridge(url?: string): Promise<WebuiBridge> {
    if (global.webui) return Promise.resolve(adopt(global.webui));
    if (global.__zigWebuiLoading) return global.__zigWebuiLoading.then(adopt);
    const source = url ?? takeBridgeUrl() ?? hostedBridgeUrl();
    if (source === null || typeof document === "undefined")
        return Promise.reject(new Error("zig-webui bridge is not available on this page"));
    const loading = inject(source);
    global.__zigWebuiLoading = loading;
    loading.catch(() => {
        if (global.__zigWebuiLoading === loading) global.__zigWebuiLoading = undefined;
    });
    return loading.then(adopt);
}

/** The loaded bridge, or `null` before `loadBridge` resolves. */
export function getBridge(): WebuiBridge | null {
    return bridge;
}

/** Whether the bridge is authenticated with the Zig application. */
export function isConnected(): boolean {
    return watching ? connected : (bridge?.isConnected() ?? false);
}

/**
 * Observe bridge loading and connection changes. The first subscriber takes
 * over the bridge's event callback, replacing its built-in loss banner.
 */
export function subscribe(listener: () => void): () => void {
    listeners.add(listener);
    if (bridge) watch(bridge);
    return () => {
        listeners.delete(listener);
    };
}

/** Call a Zig binding, loading the bridge first when needed. */
export async function call(name: string, ...args: CallArgument[]): Promise<string> {
    return (await loadBridge()).call(name, ...args);
}

/** Typed functions for the bindings declared in `T`. */
export function bindings<T extends BindingMap>(): Bindings<T> {
    return new Proxy({}, {
        get: (_, name) =>
            typeof name === "string"
                ? (...args: CallArgument[]) => call(name, ...args)
                : undefined,
    }) as Bindings<T>;
}

// Remove the development fragment before any router reads it, and start
// connecting at once. Failures surface from the first `call`/`loadBridge`.
if (typeof document !== "undefined") loadBridge().catch(() => {});
