import { createSignal, getOwner, onCleanup, type Accessor } from "solid-js";
import { getBridge, isConnected, subscribe, type WebuiBridge } from "./index.ts";

export * from "./index.ts";

function track<T>(read: () => T): Accessor<T> {
    const [value, setValue] = createSignal(read());
    const unsubscribe = subscribe(() => setValue(() => read()));
    if (getOwner()) onCleanup(unsubscribe);
    return value;
}

/** Whether the bridge is connected, as a signal. */
export function createConnected(): Accessor<boolean> {
    return track(isConnected);
}

/** The loaded bridge, or `null` until it loads, as a signal. */
export function createBridge(): Accessor<WebuiBridge | null> {
    return track(getBridge);
}
