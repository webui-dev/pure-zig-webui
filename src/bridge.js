(() => {
    const signature = 0xdd;
    const commandJs = 0xfe;
    const commandJsQuick = 0xfd;
    const commandClick = 0xfc;
    const commandNavigation = 0xfb;
    const commandClose = 0xfa;
    const commandCall = 0xf9;
    const commandRaw = 0xf8;
    const commandMulti = 0xf6;
    const multiChunkSize = 65_500;
    const commandCheckToken = 0xf5;
    const encoder = new TextEncoder();
    const decoder = new TextDecoder();
    const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
    const pending = new Map();
    const event = Object.freeze({
        CONNECTED: 0,
        DISCONNECTED: 1,
    });
    let nextId = 1;
    let connected = false;
    let logging = false;
    let allowNavigation = !globalThis.__zigWebuiEvents;
    let eventCallback = null;
    let lastEvent = -1;
    let socket = null;
    let stopped = false;
    let suspended = false;
    let retryTimer;
    let handshakeTimer;
    let heartbeatTimer;
    let pongTimer;
    let warningTimer;
    let warning = null;
    const token = globalThis.__zigWebuiToken;
    const capability = globalThis.__zigWebuiCapability;

    const bridgeSource = document.currentScript?.src
        ? new URL(document.currentScript.src)
        : new URL(location.href, `${location.protocol}//${location.host}`);
    const socketUrl = `${bridgeSource.protocol === "https:" ? "wss" : "ws"}://${bridgeSource.host}/${capability}/_webui_ws_connect`;

    function packet(command, id, payload = new Uint8Array()) {
        const bytes = new Uint8Array(8 + payload.length);
        const view = new DataView(bytes.buffer);
        bytes[0] = signature;
        view.setUint32(1, token, true);
        view.setUint16(5, id, true);
        bytes[7] = command;
        bytes.set(payload, 8);
        return bytes;
    }

    function sendData(connection, bytes) {
        try {
            if (connection !== socket || connection.readyState !== WebSocket.OPEN)
                throw new Error("WebUI is not connected");
            if (bytes.length < multiChunkSize) {
                connection.send(bytes);
                return;
            }
            const length = encoder.encode(`${bytes.length}\0`);
            const prePacket = new Uint8Array(8 + length.length);
            prePacket[0] = signature;
            prePacket[7] = commandMulti;
            prePacket.set(length, 8);
            connection.send(prePacket);
            for (let offset = 0; offset < bytes.length; offset += multiChunkSize) {
                if (connection !== socket || connection.readyState !== WebSocket.OPEN)
                    throw new Error("WebUI connection closed");
                connection.send(bytes.subarray(offset, offset + multiChunkSize));
            }
        } catch (error) {
            retire(connection, error);
            throw error;
        }
    }

    function sendEvent(command, value) {
        if (!connected) return;
        const connection = socket;
        try {
            sendData(connection, packet(command, 0, encoder.encode(value)));
        } catch {}
    }

    function log(message) {
        if (logging) console.log(`WebUI -> ${message}`);
    }

    function setConnected(value) {
        const changed = connected !== value;
        connected = value;
        if (changed) log(value ? "Connected" : "Disconnected");
        const kind = value ? event.CONNECTED : event.DISCONNECTED;
        if (!eventCallback || lastEvent === kind) return;
        lastEvent = kind;
        try {
            eventCallback(kind);
        } catch {
            log("Event callback failed");
        }
    }

    function removeWarning() {
        clearTimeout(warningTimer);
        warningTimer = undefined;
        warning?.remove();
        warning = null;
    }

    function showWarning() {
        if (connected || suspended || eventCallback) return;
        if (!warning) {
            warning = document.createElement("div");
            warning.style.cssText = "position:fixed;bottom:0;left:0;right:0;z-index:2147483647;padding:10px 16px;background:#252525;color:#fff;font:14px system-ui,sans-serif;pointer-events:none";
            (document.body || document.documentElement).appendChild(warning);
        }
        warning.setAttribute("role", stopped ? "alert" : "status");
        warning.setAttribute("aria-live", stopped ? "assertive" : "polite");
        warning.textContent = stopped
            ? "Connection to the application was rejected. Reload the page to reconnect."
            : "Connection to the application was lost. Reconnecting…";
    }

    function scheduleWarning(delay) {
        if (warningTimer !== undefined || warning || eventCallback) return;
        warningTimer = setTimeout(() => {
            warningTimer = undefined;
            showWarning();
        }, delay);
    }

    function clearSessionTimers() {
        clearTimeout(handshakeTimer);
        clearTimeout(heartbeatTimer);
        clearTimeout(pongTimer);
        handshakeTimer = heartbeatTimer = pongTimer = undefined;
    }

    function retire(connection, error = new Error("WebUI connection closed")) {
        if (!connection || connection !== socket) return;
        socket = null;
        clearSessionTimers();
        for (const promise of pending.values()) promise.reject(error);
        pending.clear();
        if (!stopped && !suspended) {
            scheduleWarning(connected ? 1000 : 5000);
            retryTimer = setTimeout(() => {
                retryTimer = undefined;
                connect();
            }, 500);
        }
        try { connection.close(); } catch {}
        setConnected(false);
    }

    function stop(permanent) {
        if (permanent) stopped = true;
        else suspended = true;
        clearTimeout(retryTimer);
        retryTimer = undefined;
        removeWarning();
        retire(socket);
    }

    function rejectConnection() {
        stop(true);
        showWarning();
    }

    function heartbeat(connection) {
        heartbeatTimer = setTimeout(() => {
            if (connection !== socket || !connected) return;
            try {
                if (connection.readyState !== WebSocket.OPEN)
                    throw new Error("WebUI connection closed");
                connection.send("ping");
            } catch (error) {
                retire(connection, error);
                return;
            }
            pongTimer = setTimeout(() => retire(connection), 10_000);
            heartbeat(connection);
        }, 20_000);
    }

    // ponytail: Zig filters IDs to avoid injecting names; send a filtered
    // list only if pages with many unrelated IDs make click traffic matter.
    if (globalThis.__zigWebuiEvents || globalThis.__zigWebuiDomBindings) {
        document.addEventListener("click", (event) => {
            const element = event.target?.closest?.("[id]");
            if (element && element.id) sendEvent(commandClick, element.id);

            if (globalThis.__zigWebuiEvents &&
                !allowNavigation &&
                !("navigation" in globalThis))
            {
                const link = event.target?.closest?.("a[href]");
                if (link && connected) {
                    event.preventDefault();
                    sendEvent(commandNavigation, link.href);
                }
            }
        });
    }
    if (globalThis.__zigWebuiEvents && "navigation" in globalThis) {
        globalThis.navigation.addEventListener("navigate", (event) => {
            if (!connected || allowNavigation) return;
            if (event.cancelable) event.preventDefault();
            sendEvent(commandNavigation, event.destination.url);
        });
    }

    function connect() {
        if (stopped || suspended || socket) return;
        let connection;
        try {
            connection = new WebSocket(socketUrl);
        } catch {
            retryTimer = setTimeout(() => {
                retryTimer = undefined;
                connect();
            }, 500);
            return;
        }
        socket = connection;
        connection.binaryType = "arraybuffer";
        handshakeTimer = setTimeout(() => retire(connection), 5000);
        connection.onopen = () => {
            if (connection !== socket) return;
            try {
                sendData(connection, packet(commandCheckToken, 0, encoder.encode(capability)));
            } catch {}
        };
        // WebSocket errors are followed by close; only close carries the
        // policy/protocol code that decides whether reconnecting is allowed.
        connection.onclose = ({ code } = {}) => {
            if (connection !== socket) return;
            if ([1002, 1003, 1007, 1008, 1009].includes(code)) rejectConnection();
            else retire(connection);
        };
        connection.onmessage = ({ data }) => receive(connection, data);
    }

    async function receive(connection, data) {
        if (connection !== socket || connection.readyState !== WebSocket.OPEN) return;
        if (typeof data === "string") {
            if (connected && data === "pong") {
                clearTimeout(pongTimer);
                pongTimer = undefined;
            }
            return;
        }
        const bytes = new Uint8Array(data);
        if (bytes.length < 8 || bytes[0] !== signature) return;
        const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
        if (view.getUint32(1, true) !== token) {
            rejectConnection();
            return;
        }
        const id = view.getUint16(5, true);
        if (bytes[7] === commandCheckToken) {
            if (bytes.length <= 8 || bytes[8] !== 1) {
                rejectConnection();
                return;
            }
            if (!connected) {
                clearTimeout(handshakeTimer);
                handshakeTimer = undefined;
                removeWarning();
                heartbeat(connection);
                setConnected(true);
            }
            return;
        }
        if (!connected) return;
        if (bytes[7] === commandJs || bytes[7] === commandJsQuick) {
            let failed = 0;
            let value;
            try {
                const source = decoder.decode(bytes.subarray(8)).replace(/\0$/, "");
                const result = await AsyncFunction(source)();
                value = result instanceof Uint8Array
                    ? result
                    : encoder.encode(String(result));
            } catch (error) {
                failed = 1;
                value = encoder.encode(
                    error instanceof Error ? error.message : String(error),
                );
            }
            if (bytes[7] === commandJsQuick || connection !== socket || !connected) return;
            const response = new Uint8Array(value.length + 2);
            response[0] = failed;
            response.set(value, 1);
            try {
                sendData(connection, packet(commandJs, id, response));
            } catch {}
            return;
        }
        if (bytes[7] === commandNavigation) {
            // Backend-initiated navigation bypasses our own interception,
            // matching upstream, which re-allows navigation before leaving;
            // otherwise the navigate listener would bounce it back to Zig.
            allowNavigation = true;
            location.href = decoder.decode(bytes.subarray(8));
            return;
        }
        if (bytes[7] === commandClose) {
            stop(true);
            globalThis.close();
            return;
        }
        if (bytes[7] === commandRaw) {
            const separator = bytes.indexOf(0, 8);
            if (separator < 0) return;
            const functionName = decoder.decode(bytes.subarray(8, separator));
            const callback = globalThis[functionName];
            if (typeof callback === "function")
                callback(bytes.subarray(separator + 1));
            return;
        }
        if (bytes[7] === commandCall) {
            const promise = pending.get(id);
            if (promise) {
                pending.delete(id);
                promise.resolve(decoder.decode(bytes.subarray(8)));
            }
        }
    }

    globalThis.addEventListener("pagehide", () => stop(false));
    globalThis.addEventListener("pageshow", ({ persisted }) => {
        if (!persisted || stopped || !suspended) return;
        suspended = false;
        scheduleWarning(5000);
        connect();
    });

    globalThis.webui = {
        event,
        isConnected: () => connected,
        call(name, ...args) {
            if (!connected) return Promise.reject(new Error("WebUI is not connected"));
            const connection = socket;
            log(`Calling [${name}(...)]`);
            const values = args.map((arg) =>
                arg instanceof Uint8Array ? arg : encoder.encode(String(arg)),
            );
            const lengths = encoder.encode(values.map((value) => value.length).join(";"));
            const nameBytes = encoder.encode(name);
            const size =
                nameBytes.length + 1 +
                lengths.length + 1 +
                values.reduce((total, value) => total + value.length + 1, 0);
            const payload = new Uint8Array(size);
            let at = 0;
            payload.set(nameBytes, at);
            at += nameBytes.length + 1;
            payload.set(lengths, at);
            at += lengths.length + 1;
            for (const value of values) {
                payload.set(value, at);
                at += value.length + 1;
            }

            // Serialization can invoke user code, so check capacity and choose
            // an ID only after any reentrant calls have reserved their slots.
            if (!connected || connection !== socket)
                return Promise.reject(new Error("WebUI is not connected"));
            if (pending.size === 0xffff)
                return Promise.reject(new Error("WebUI has too many pending calls"));
            while (pending.has(nextId))
                nextId = nextId === 0xffff ? 1 : nextId + 1;
            const id = nextId;
            nextId = nextId === 0xffff ? 1 : nextId + 1;
            return new Promise((resolve, reject) => {
                pending.set(id, { resolve, reject });
                try {
                    sendData(connection, packet(commandCall, id, payload));
                } catch (error) {
                    pending.delete(id);
                    reject(error);
                }
            });
        },
        setLogging(status) {
            logging = Boolean(status);
            console.log(`WebUI -> Log ${logging ? "Enabled" : "Disabled"}.`);
        },
        encode(data) {
            return globalThis.btoa(data);
        },
        decode(data) {
            return globalThis.atob(data);
        },
        setEventCallback(callback) {
            if (typeof callback !== "function")
                throw new TypeError("Event callback must be a function");
            eventCallback = callback;
            removeWarning();
        },
        async isHighContrast() {
            if (globalThis.matchMedia?.("(forced-colors: active)").matches)
                return true;
            return globalThis.matchMedia?.("(prefers-contrast: more)").matches ?? false;
        },
        allowNavigation(status) {
            allowNavigation = Boolean(status);
        },
    };

    scheduleWarning(5000);
    connect();
})();
