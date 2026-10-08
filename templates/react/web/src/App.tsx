import { useState, type FormEvent } from "react";
import { bindings, useConnected } from "zig-webui/react";

// Bindings registered with `window.bind` in src/main.zig.
const zig = bindings<{ greet: [name: string] }>();

export function App() {
  const connected = useConnected();
  const [name, setName] = useState("React");
  const [reply, setReply] = useState("");

  async function greet(event: FormEvent) {
    event.preventDefault();
    setReply(await zig.greet(name));
  }

  return (
    <main>
      <h1>zig-webui + React</h1>
      <p className="status">{connected ? "Connected to Zig" : "Connecting…"}</p>
      <form onSubmit={greet}>
        <input value={name} onChange={(event) => setName(event.target.value)} />
        <button disabled={!connected}>Greet</button>
      </form>
      <output>{reply}</output>
    </main>
  );
}
