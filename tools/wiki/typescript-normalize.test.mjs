import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  TYPESCRIPT_ENTRY_PAGE,
  TYPESCRIPT_PROTOS_PAGE,
  assertValidTypeScriptCoverage,
  formatTypeScriptProtoSignature,
  managedTypeScriptPageName,
  normalizeTypeScriptWiki,
  parseTypeScriptProtos,
  rewriteTypeScriptWikiLinks,
} from "./typescript-normalize.mjs";

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const PROTOS_SOURCE = path.join(REPO_ROOT, "bindings", "typescript", "src", "lowlevel", "protos.ts");
const METADATA = {
  tag: "v0.1.5",
  sha: "0123456789abcdef0123456789abcdef01234567",
  repository: "anhydrous99/zigfitsio",
  packageVersion: "0.1.5",
};
const TOOLCHAIN = {
  typedoc: "0.28.20",
  typedocPluginMarkdown: "4.12.0",
  typedocGithubWikiTheme: "2.1.0",
  typescript: "6.0.3",
};

test("parses every literal PROTOS declaration in source order", async () => {
  const protos = parseTypeScriptProtos(await readFile(PROTOS_SOURCE, "utf8"));
  assert.equal(protos.length, 89);
  assert.equal(protos[0].name, "zf_version");
  assert.equal(protos.at(-1).name, "zf_write_compressed3");
  assert.equal(new Set(protos.map((proto) => proto.name)).size, protos.length);
  assert.equal(formatTypeScriptProtoSignature(protos[0]), "lib.zf_version(): string");
  assert.match(formatTypeScriptProtoSignature(protos.at(-1)), /^lib\.zf_write_compressed3\(/);
});

test("TypeDoc configuration fixes the two public package entry points", async () => {
  const config = JSON.parse(
    await readFile(path.join(REPO_ROOT, "bindings", "typescript", "typedoc.wiki.json"), "utf8"),
  );
  assert.deepEqual(config.entryPoints, ["src/index.ts", "src/lowlevel/index.ts"]);
  assert.equal(config.entryPointStrategy, "resolve");
  assert.equal(config.entryFileName, TYPESCRIPT_ENTRY_PAGE);
  assert.equal(config.sidebar.autoConfiguration, false);
});

test("rejects a non-literal PROTOS call so coverage cannot silently shrink", () => {
  assert.throws(
    () => parseTypeScriptProtos('export const PROTOS = [\n  p(dynamicName, "int"),\n];'),
    /parsed 0 of 1 PROTOS calls/,
  );
});

test("prefixes every TypeDoc page and reserves no global wiki names", () => {
  assert.equal(managedTypeScriptPageName("TypeScript-API.md"), "TypeScript-API.md");
  assert.equal(managedTypeScriptPageName("index.md"), "TypeScript-API-High-Level.md");
  assert.equal(
    managedTypeScriptPageName("index.Class.HDUList.md"),
    "TypeScript-API-High-Level.Class.HDUList.md",
  );
  assert.equal(managedTypeScriptPageName("lowlevel.md"), "TypeScript-API-Low-Level.md");
  assert.equal(
    managedTypeScriptPageName("lowlevel.Function.check.md"),
    "TypeScript-API-Low-Level.Function.check.md",
  );
  assert.throws(() => managedTypeScriptPageName("Home.md"), /unexpected TypeDoc page/);
  assert.throws(() => managedTypeScriptPageName("_Sidebar.md"), /unexpected TypeDoc page/);
});

test("rewrites theme links through the managed page map and reports unknown targets", () => {
  const mapping = new Map([
    ["index", "TypeScript-API-High-Level"],
    ["index.Class.HDUList", "TypeScript-API-High-Level.Class.HDUList"],
  ]);
  const result = rewriteTypeScriptWikiLinks(
    "[index](../wiki/index) [class](../wiki/index.Class.HDUList#methods) [bad](../wiki/missing)",
    mapping,
  );
  assert.match(result.markdown, /\.\.\/wiki\/TypeScript-API-High-Level\)/);
  assert.match(result.markdown, /TypeScript-API-High-Level\.Class\.HDUList#methods/);
  assert.deepEqual(result.unresolved, ["missing"]);
});

test("normalizes a miniature two-entrypoint project and validates symbol/prototype coverage", async () => {
  const temporary = await mkdtemp(path.join(os.tmpdir(), "zigfitsio-ts-normalize-test-"));
  const raw = path.join(temporary, "raw");
  await mkdir(raw);
  try {
    await Promise.all([
      writeFile(
        path.join(raw, TYPESCRIPT_ENTRY_PAGE),
        "# zigfitsio\n\n- [index](../wiki/index)\n- [lowlevel](../wiki/lowlevel)\n",
      ),
      writeFile(path.join(raw, "index.md"), "[zigfitsio](../wiki/TypeScript-API) / index\n\n# index\n\n[open](../wiki/index.Function.open)\n"),
      writeFile(path.join(raw, "index.Function.open.md"), "# Function: open\n\n> **open**(): void\n"),
      writeFile(path.join(raw, "index.Class.Box.md"), "# Class: Box\n\n## Properties\n\n### value\n\n> **value**: string\n"),
      writeFile(path.join(raw, "lowlevel.md"), "[zigfitsio](../wiki/TypeScript-API) / lowlevel\n\n# lowlevel\n\n[lib](../wiki/lowlevel.Variable.lib)\n"),
      writeFile(path.join(raw, "lowlevel.Variable.lib.md"), "# Variable: lib\n\n> `const` **lib**: object\n"),
    ]);
    const reflection = {
      children: [
        {
          name: "index",
          kind: 2,
          sources: [{ fileName: "src/index.ts", line: 1 }],
          children: [
            { name: "open", kind: 64, sources: [{ fileName: "bindings/typescript/src/index.ts", line: 9 }] },
            {
              name: "Box",
              kind: 128,
              sources: [{ fileName: "bindings/typescript/src/index.ts", line: 10 }],
              children: [
                { name: "value", kind: 1024, sources: [{ fileName: "bindings/typescript/src/index.ts", line: 11 }] },
              ],
            },
          ],
        },
        {
          name: "lowlevel",
          kind: 2,
          sources: [{ fileName: "src/lowlevel/index.ts", line: 1 }],
          children: [{ name: "lib", kind: 32, sources: [{ fileName: "bindings/typescript/src/lowlevel/index.ts", line: 110 }] }],
        },
      ],
    };
    const normalized = await normalizeTypeScriptWiki({
      rawDirectory: raw,
      reflection,
      protosSource: 'export const PROTOS = [\n  p("zf_version", "cstring_ret"),\n  p("zf_close", "void", "handle"),\n];\n',
      metadata: METADATA,
      toolchain: TOOLCHAIN,
    });
    assertValidTypeScriptCoverage(normalized.coverage);
    assert.equal(normalized.coverage.typedocSymbols.documented, 4);
    assert.equal(normalized.coverage.dynamicPrototypes.documented, 2);
    assert.ok(normalized.pages.has(TYPESCRIPT_PROTOS_PAGE));
    assert.ok([...normalized.pages.keys()].every((name) => name.startsWith("TypeScript-API")));
    assert.ok(!normalized.pages.has("Home.md"));
    assert.ok(!normalized.pages.has("_Sidebar.md"));
    assert.deepEqual(normalized.manifest.managedPages, [...normalized.manifest.managedPages].sort());
    assert.equal(
      normalized.manifest.symbols.typedoc.find((symbol) => symbol.qualifiedName === "index.Box.value")?.page,
      "TypeScript-API-High-Level.Class.Box.md",
    );
    assert.match(normalized.pages.get(TYPESCRIPT_ENTRY_PAGE), /v0\.1\.5/);
    assert.match(normalized.pages.get(TYPESCRIPT_PROTOS_PAGE), /lib\.zf_close\(arg0: bigint \| number \| null\): undefined/);

    await writeFile(
      path.join(raw, "index.Class.Box.md"),
      "# Class: Box\n\n## Properties\n\n### value\n\nDescription without a signature.\n\n```md\n### value\n```\n",
    );
    const missingMember = await normalizeTypeScriptWiki({
      rawDirectory: raw,
      reflection,
      protosSource: 'export const PROTOS = [\n  p("zf_version", "cstring_ret"),\n];\n',
      metadata: METADATA,
      toolchain: TOOLCHAIN,
    });
    assert.deepEqual(missingMember.coverage.typedocSymbols.missing, ["index.Box.value"]);
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
});
