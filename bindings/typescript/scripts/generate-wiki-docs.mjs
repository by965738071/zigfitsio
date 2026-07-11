#!/usr/bin/env node

import { spawn } from "node:child_process";
import { mkdtemp, mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  TYPESCRIPT_COVERAGE_FILE,
  TYPESCRIPT_MANIFEST_FILE,
  assertValidTypeScriptCoverage,
  normalizeTypeScriptWiki,
} from "../../../tools/wiki/typescript-normalize.mjs";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const PACKAGE_ROOT = path.resolve(SCRIPT_DIR, "..");

function usage() {
  return [
    "Generate deterministic, GitHub-Wiki-native TypeScript API documentation.",
    "",
    "Usage:",
    "  node bindings/typescript/scripts/generate-wiki-docs.mjs \\",
    "    --out <staging-directory> --tag <vX.Y.Z> --sha <40-hex> --repository <owner/repo>",
  ].join("\n");
}

function parseArgs(argv) {
  const options = {};
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--help" || arg === "-h") return { help: true };
    if (!["--out", "--tag", "--sha", "--repository"].includes(arg)) throw new Error(`unknown argument: ${arg}`);
    const value = argv[index + 1];
    if (!value || value.startsWith("--")) throw new Error(`${arg} requires a value`);
    const key = arg.slice(2);
    if (options[key]) throw new Error(`${arg} was supplied more than once`);
    options[key] = value;
    index += 1;
  }
  for (const key of ["out", "tag", "sha", "repository"]) {
    if (!options[key]) throw new Error(`--${key} is required`);
  }
  if (!/^v\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/.test(options.tag)) {
    throw new Error(`invalid release tag: ${options.tag}`);
  }
  if (!/^[0-9a-fA-F]{40}$/.test(options.sha)) throw new Error("--sha must be a full 40-character commit SHA");
  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(options.repository)) {
    throw new Error(`invalid GitHub repository: ${options.repository}`);
  }
  return {
    out: path.resolve(options.out),
    tag: options.tag,
    sha: options.sha.toLowerCase(),
    repository: options.repository,
  };
}

async function packageJsonAt(relativePath) {
  return JSON.parse(await readFile(path.join(PACKAGE_ROOT, relativePath), "utf8"));
}

async function runTypeDoc({ rawPages, reflectionFile, sha, repository }) {
  const typedocBin = path.join(PACKAGE_ROOT, "node_modules", "typedoc", "bin", "typedoc");
  const config = path.join(PACKAGE_ROOT, "typedoc.wiki.json");
  // With TypeDoc's inferred base path (`bindings/typescript/src`), `{path}` is source-relative.
  // Keeping `basePath` implicit also preserves the requested entry-module names (`index` and
  // `lowlevel`); setting it to the repository root changes them to filesystem-derived names.
  const sourceTemplate = `https://github.com/${repository}/blob/{gitRevision}/bindings/typescript/src/{path}#L{line}`;
  const args = [
    typedocBin,
    "--options",
    config,
    "--out",
    rawPages,
    "--json",
    reflectionFile,
    "--disableGit",
    "--sourceLinkTemplate",
    sourceTemplate,
    "--gitRevision",
    sha,
  ];
  await new Promise((resolve, reject) => {
    const child = spawn(process.execPath, args, { cwd: PACKAGE_ROOT, stdio: "inherit" });
    child.once("error", reject);
    child.once("exit", (code, signal) => {
      if (code === 0) resolve();
      else reject(new Error(`TypeDoc failed${signal ? ` with signal ${signal}` : ` with exit code ${code}`}`));
    });
  });
}

async function readPreviousManagedPages(outputDirectory) {
  try {
    const manifest = JSON.parse(await readFile(path.join(outputDirectory, TYPESCRIPT_MANIFEST_FILE), "utf8"));
    if (manifest.language !== "typescript" || !Array.isArray(manifest.managedPages)) {
      throw new Error(`${TYPESCRIPT_MANIFEST_FILE} is not a TypeScript wiki manifest`);
    }
    for (const page of manifest.managedPages) {
      if (path.basename(page) !== page || !page.startsWith("TypeScript-API") || !page.endsWith(".md")) {
        throw new Error(`unsafe managed page in previous manifest: ${page}`);
      }
    }
    return manifest.managedPages;
  } catch (error) {
    if (error?.code === "ENOENT") return [];
    throw error;
  }
}

async function atomicWrite(file, contents) {
  const temporary = `${file}.tmp-${process.pid}`;
  await writeFile(temporary, contents, "utf8");
  await rm(file, { force: true });
  await rename(temporary, file);
}

async function publishNormalizedOutput(outputDirectory, normalized) {
  await mkdir(outputDirectory, { recursive: true });
  const previousPages = await readPreviousManagedPages(outputDirectory);
  const nextPages = new Set(normalized.manifest.managedPages);

  for (const [name, contents] of [...normalized.pages.entries()].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))) {
    await atomicWrite(path.join(outputDirectory, name), contents);
  }
  for (const stale of previousPages.filter((page) => !nextPages.has(page))) {
    await rm(path.join(outputDirectory, stale), { force: true });
  }
  await atomicWrite(path.join(outputDirectory, TYPESCRIPT_COVERAGE_FILE), normalized.coverageText);
  await atomicWrite(path.join(outputDirectory, TYPESCRIPT_MANIFEST_FILE), normalized.manifestText);
}

async function main() {
  let options;
  try {
    options = parseArgs(process.argv.slice(2));
  } catch (error) {
    console.error(error.message);
    console.error(usage());
    process.exitCode = 2;
    return;
  }
  if (options.help) {
    console.log(usage());
    return;
  }

  const packageJson = await packageJsonAt("package.json");
  const packageLock = await packageJsonAt("package-lock.json");
  const tagVersion = options.tag.slice(1);
  if (tagVersion !== packageJson.version) {
    throw new Error(`release tag ${options.tag} does not match package.json ${packageJson.version}`);
  }
  if (packageLock.version !== packageJson.version || packageLock.packages?.[""]?.version !== packageJson.version) {
    throw new Error("package-lock.json root versions do not match package.json");
  }

  const toolchain = {
    typedoc: packageLock.packages["node_modules/typedoc"].version,
    typedocPluginMarkdown: packageLock.packages["node_modules/typedoc-plugin-markdown"].version,
    typedocGithubWikiTheme: packageLock.packages["node_modules/typedoc-github-wiki-theme"].version,
    typescript: packageLock.packages["node_modules/typescript"].version,
  };
  const temporaryRoot = await mkdtemp(path.join(os.tmpdir(), "zigfitsio-typescript-wiki-"));
  const rawPages = path.join(temporaryRoot, "pages");
  const reflectionFile = path.join(temporaryRoot, "reflection.json");

  try {
    await runTypeDoc({ rawPages, reflectionFile, sha: options.sha, repository: options.repository });
    const [reflection, protosSource] = await Promise.all([
      readFile(reflectionFile, "utf8").then(JSON.parse),
      readFile(path.join(PACKAGE_ROOT, "src", "lowlevel", "protos.ts"), "utf8"),
    ]);
    const normalized = await normalizeTypeScriptWiki({
      rawDirectory: rawPages,
      reflection,
      protosSource,
      metadata: {
        tag: options.tag,
        sha: options.sha,
        repository: options.repository,
        packageVersion: packageJson.version,
      },
      toolchain,
    });
    assertValidTypeScriptCoverage(normalized.coverage);
    await publishNormalizedOutput(options.out, normalized);
    console.log(
      JSON.stringify({
        outputDirectory: options.out,
        manifest: path.join(options.out, TYPESCRIPT_MANIFEST_FILE),
        managedPages: normalized.manifest.managedPages.length,
        typedocSymbols: normalized.coverage.typedocSymbols.documented,
        dynamicPrototypes: normalized.coverage.dynamicPrototypes.documented,
      }),
    );
  } finally {
    if (process.env.KEEP_TYPESCRIPT_WIKI_TEMP !== "1") await rm(temporaryRoot, { recursive: true, force: true });
    else console.error(`kept TypeDoc temporary output at ${temporaryRoot}`);
  }
}

main().catch((error) => {
  console.error(error?.stack ?? String(error));
  process.exitCode = 1;
});
