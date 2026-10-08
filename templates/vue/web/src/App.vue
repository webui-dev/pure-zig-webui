<script setup lang="ts">
import { ref } from "vue";
import { bindings, useConnected } from "zig-webui/vue";

// Bindings registered with `window.bind` in src/main.zig.
const zig = bindings<{ greet: [name: string] }>();
const connected = useConnected();
const name = ref("Vue");
const reply = ref("");

async function greet() {
  reply.value = await zig.greet(name.value);
}
</script>

<template>
  <main>
    <h1>zig-webui + Vue</h1>
    <p class="status">{{ connected ? "Connected to Zig" : "Connecting…" }}</p>
    <form @submit.prevent="greet">
      <input v-model="name" />
      <button :disabled="!connected">Greet</button>
    </form>
    <output>{{ reply }}</output>
  </main>
</template>
