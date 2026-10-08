import { computed, getCurrentScope, onScopeDispose, shallowRef, type ComputedRef } from "vue";
import { getBridge, isConnected, subscribe, type WebuiBridge } from "./index.ts";

export * from "./index.ts";

function track<T>(read: () => T): ComputedRef<T> {
    const value = shallowRef(read());
    const unsubscribe = subscribe(() => {
        value.value = read();
    });
    if (getCurrentScope()) onScopeDispose(unsubscribe);
    return computed(() => value.value);
}

/** Whether the bridge is connected, as a read-only ref. */
export function useConnected(): ComputedRef<boolean> {
    return track(isConnected);
}

/** The loaded bridge, or `null` until it loads, as a read-only ref. */
export function useBridge(): ComputedRef<WebuiBridge | null> {
    return track(getBridge);
}
