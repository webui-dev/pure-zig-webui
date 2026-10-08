import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { after, test } from "node:test";
import { crc32 } from "node:zlib";
import { create, fingerprint } from "../src/create.ts";

const root = resolve(import.meta.dirname, "../..");
const scratch = mkdtempSync(join(tmpdir(), "zig-webui-create-"));
after(() => rmSync(scratch, { recursive: true, force: true }));

test("fingerprints pair a random id with the CRC-32 of the package name", () => {
    assert.equal(fingerprint("demo_app", 0x1234), `0x${crc32("demo_app").toString(16).padStart(8, "0")}00001234`);
    const id = BigInt(fingerprint("x")) & 0xffffffffn;
    assert.ok(id !== 0n && id !== 0xffffffffn);
});

for (const [template, entry, marker] of [
    ["react", "web/src/App.tsx", "zig-webui/react"],
    ["vue", "web/src/App.vue", "zig-webui/vue"],
    ["solid", "web/src/App.tsx", "zig-webui/solid"],
] as const) {
    test(`${template} apps get the shared Zig host and path dependencies`, () => {
        const target = join(scratch, `my-${template}-app`);
        create(target, template);
        for (const file of ["build.zig", "src/main.zig", ".gitignore", "README.md", "web/src/style.css", entry])
            assert.ok(existsSync(join(target, file)), file);
        assert.ok(readFileSync(join(target, entry), "utf8").includes(marker));

        const zon = readFileSync(join(target, "build.zig.zon"), "utf8");
        const name = `my_${template}_app`;
        assert.match(zon, new RegExp(`\\.name = \\.${name},`));
        const value = BigInt(/\.fingerprint = (0x[0-9a-f]{16})/.exec(zon)![1]);
        assert.equal(Number(value >> 32n), crc32(name));
        const path = /\.path = "([^"]+)"/.exec(zon)![1];
        assert.equal(resolve(target, path), root);

        const manifest = JSON.parse(readFileSync(join(target, "web/package.json"), "utf8"));
        assert.equal(manifest.name, `my-${template}-app-web`);
        assert.equal(resolve(target, "web", manifest.dependencies["zig-webui"].slice("file:".length)), join(root, "sdk"));
        for (const file of ["build.zig", "README.md", "web/package.json", "web/index.html"])
            assert.doesNotMatch(readFileSync(join(target, file), "utf8"), /__[A-Z]+__/, file);
    });
}

test("invalid names, unknown templates, and non-empty targets are refused", () => {
    assert.throws(() => create(join(scratch, "Bad Name"), "react"), /must start with a lowercase letter/);
    assert.throws(() => create(join(scratch, "fine"), "svelte" as "react"), /unknown template "svelte"/);
    const occupied = join(scratch, "occupied");
    mkdirSync(occupied);
    writeFileSync(join(occupied, "keep.txt"), "mine");
    assert.throws(() => create(occupied, "vue"), /is not empty/);
    assert.equal(readFileSync(join(occupied, "keep.txt"), "utf8"), "mine");
    assert.equal(existsSync(join(scratch, "fine")), false);
});
