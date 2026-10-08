import { createSignal } from "solid-js";
import { bindings, createConnected } from "zig-webui/solid";

// Bindings registered with `window.bind` in src/main.zig.
const zig = bindings<{ greet: [name: string] }>();

export function App() {
  const connected = createConnected();
  const [name, setName] = createSignal("Solid");
  const [reply, setReply] = createSignal("");

  async function greet(event: SubmitEvent) {
    event.preventDefault();
    setReply(await zig.greet(name()));
  }

  return (
    <main>
      <h1>zig-webui + Solid</h1>
      <p class="status">{connected() ? "Connected to Zig" : "Connecting…"}</p>
      <form onSubmit={greet}>
        <input value={name()} onInput={(event) => setName(event.currentTarget.value)} />
        <button disabled={!connected()}>Greet</button>
      </form>
      <output>{reply()}</output>
    </main>
  );
}
