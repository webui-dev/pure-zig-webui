import { useSyncExternalStore } from "react";
import { getBridge, isConnected, subscribe, type WebuiBridge } from "./index.ts";

export * from "./index.ts";

/** Whether the bridge is connected; re-renders on every change. */
export function useConnected(): boolean {
    return useSyncExternalStore(subscribe, isConnected, () => false);
}

/** The loaded bridge, or `null` until it loads. */
export function useBridge(): WebuiBridge | null {
    return useSyncExternalStore(subscribe, getBridge, () => null);
}
