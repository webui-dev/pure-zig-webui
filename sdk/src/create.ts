#!/usr/bin/env node
// Scaffold a zig-webui app: `create-zig-webui <directory> [--template react|vue|solid]`.
// The app depends on this checkout of zig-webui (Zig package and SDK) by path.
import { cpSync, existsSync, mkdirSync, readdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { basename, join, relative, resolve, sep } from "node:path";
import { randomInt } from "node:crypto";
import { fileURLToPath } from "node:url";
import { crc32 } from "node:zlib";

export const templates = { react: "React", vue: "Vue", solid: "Solid" } as const;
export type Template = keyof typeof templates;

const root = fileURLToPath(new URL("../../", import.meta.url));
const sdk = join(root, "sdk");

function posix(path: string): string {
    return path.split(sep).join("/");
}

/** `build.zig.zon` fingerprint: random id, CRC-32 of the package name. */
export function fingerprint(name: string, id = randomInt(1, 0xffffffff)): string {
    return `0x${((BigInt(crc32(name)) << 32n) | BigInt(id)).toString(16).padStart(16, "0")}`;
}

function replaceIn(path: string, values: Record<string, string>) {
    let text = readFileSync(path, "utf8");
    for (const [key, value] of Object.entries(values)) text = text.replaceAll(key, value);
    writeFileSync(path, text);
}

/** Create the app in `directory`, which must be missing or empty. */
export function create(directory: string, template: Template) {
    const target = resolve(directory);
    const name = basename(target);
    if (!/^[a-z][a-z0-9_-]*$/.test(name))
        throw new Error(`project name "${name}" must start with a lowercase letter and use only a-z, 0-9, - and _`);
    if (!(template in templates))
        throw new Error(`unknown template "${template}"; use ${Object.keys(templates).join(", ")}`);
    if (existsSync(target) && readdirSync(target).length > 0)
        throw new Error(`${target} is not empty`);

    const shared = join(root, "templates", "shared");
    mkdirSync(target, { recursive: true });
    cpSync(join(root, "templates", template), target, { recursive: true });
    cpSync(join(shared, "build.zig"), join(target, "build.zig"));
    cpSync(join(shared, "src"), join(target, "src"), { recursive: true });
    cpSync(join(shared, "README.md"), join(target, "README.md"));
    cpSync(join(shared, "style.css"), join(target, "web", "src", "style.css"));
    // npm drops files named .gitignore from packages, so templates ship it renamed.
    cpSync(join(shared, "gitignore"), join(target, ".gitignore"));

    const zigName = name.replaceAll("-", "_");
    writeFileSync(join(target, "build.zig.zon"), `.{
    .name = .${zigName},
    .version = "0.0.0",
    .fingerprint = ${fingerprint(zigName)},
    .minimum_zig_version = "0.17.0",
    .dependencies = .{
        .zig_webui = .{ .path = "${posix(relative(target, root)) || "."}" },
    },
    .paths = .{ "build.zig", "build.zig.zon", "src" },
}
`);
    const values = {
        __NAME__: name,
        __FRAMEWORK__: templates[template],
        __SDK__: `file:${posix(relative(join(target, "web"), sdk))}`,
    };
    for (const file of ["build.zig", "README.md", "web/package.json", "web/index.html"])
        replaceIn(join(target, file), values);
    return target;
}

function main(args: string[]) {
    let template: string = "react";
    const positional: string[] = [];
    for (let i = 0; i < args.length; i++) {
        if (args[i] === "--template" || args[i] === "-t") template = args[++i] ?? "";
        else if (args[i].startsWith("--template=")) template = args[i].slice("--template=".length);
        else positional.push(args[i]);
    }
    if (positional.length !== 1) {
        console.error(`usage: create-zig-webui <directory> [--template ${Object.keys(templates).join("|")}]`);
        process.exitCode = 2;
        return;
    }
    try {
        const target = create(positional[0], template as Template);
        const shown = posix(relative(process.cwd(), target)) || ".";
        console.log(`Created ${templates[template as Template]} app in ${target}

  cd ${shown}/web && npm install && cd ..
  zig build run      # build the frontend and open the app

  # hot reload: \`npm run dev\` in web/, then \`zig build dev\``);
    } catch (error) {
        console.error(`create-zig-webui: ${error instanceof Error ? error.message : error}`);
        process.exitCode = 1;
    }
}

// npm links bins, so compare real paths to tell a run from an import.
if (process.argv[1] && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url)))
    main(process.argv.slice(2));
