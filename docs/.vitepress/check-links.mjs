// Validates internal doc links — both page targets and #anchors — against the
// actually-generated HTML in docs/.vitepress/dist. VitePress's own dead-link
// check does not validate anchor fragments, so those rot silently otherwise.
//
// Usage: yarn docs:build && node docs/.vitepress/check-links.mjs
// Exits non-zero (and prints every broken link) if anything fails to resolve.

import { readFileSync, readdirSync, existsSync, statSync } from "node:fs";
import { join, dirname, resolve, relative } from "node:path";
import { fileURLToPath } from "node:url";

const DOCS = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const DIST = join(DOCS, ".vitepress", "dist");

if (!existsSync(DIST)) {
  console.error(`No build output at ${DIST}. Run \`yarn docs:build\` first.`);
  process.exit(2);
}

// Recursively collect files matching a predicate.
function walk(dir, pred, acc = []) {
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    const st = statSync(full);
    if (st.isDirectory()) {
      if (name === "node_modules" || name === "dist") continue;
      walk(full, pred, acc);
    } else if (pred(full)) {
      acc.push(full);
    }
  }
  return acc;
}

// Map every built .html file -> Set of element ids it defines.
const idCache = new Map();
function idsFor(htmlPath) {
  if (idCache.has(htmlPath)) return idCache.get(htmlPath);
  const ids = new Set();
  if (existsSync(htmlPath)) {
    const html = readFileSync(htmlPath, "utf8");
    for (const m of html.matchAll(/\bid="([^"]+)"/g)) ids.add(m[1]);
    for (const m of html.matchAll(/\bname="([^"]+)"/g)) ids.add(m[1]);
  }
  idCache.set(htmlPath, ids);
  return ids;
}

// Resolve a markdown link target to its built .html path.
// `srcRoute` is the source file's route dir (e.g. "/reference").
function resolveTarget(target, srcRoute) {
  let pathPart = target;
  if (pathPart.startsWith("/")) {
    pathPart = pathPart.slice(1);
  } else {
    pathPart = relative(DOCS, resolve(join(DOCS, srcRoute.slice(1)), pathPart));
  }
  if (pathPart === "" || pathPart.endsWith("/")) pathPart += "index";
  if (pathPart.endsWith(".md")) pathPart = pathPart.slice(0, -3);
  if (!pathPart.endsWith(".html")) pathPart += ".html";
  return join(DIST, pathPart);
}

const mdFiles = walk(DOCS, (f) => f.endsWith(".md"));
const linkRe = /\[(?:[^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g;
const failures = [];

for (const md of mdFiles) {
  const lines = readFileSync(md, "utf8").split("\n");
  // Route of the source file relative to docs root, e.g. "/reference".
  const srcRoute = "/" + (relative(DOCS, dirname(md)) || "");
  let inFence = false;
  lines.forEach((line, i) => {
    if (/^\s*```/.test(line)) inFence = !inFence;
    if (inFence) return;
    for (const m of line.matchAll(linkRe)) {
      const raw = m[1];
      if (/^(https?:|mailto:|tel:|#?$)/.test(raw)) {
        // External or empty. Pure same-page anchors handled below via leading '#'.
        if (!raw.startsWith("#")) continue;
      }
      const [path, hash] = raw.split("#");
      const htmlPath = path === "" ? mdToHtml(md) : resolveTarget(path, srcRoute);
      const where = `${relative(DOCS, md)}:${i + 1}`;
      if (!existsSync(htmlPath)) {
        failures.push(`${where}  ->  ${raw}  (page not found: ${relative(DIST, htmlPath)})`);
        continue;
      }
      if (hash) {
        const ids = idsFor(htmlPath);
        if (!ids.has(hash)) {
          failures.push(`${where}  ->  ${raw}  (no #${hash} in ${relative(DIST, htmlPath)})`);
        }
      }
    }
  });
}

function mdToHtml(md) {
  const rel = relative(DOCS, md).replace(/\.md$/, ".html");
  return join(DIST, rel);
}

if (failures.length) {
  console.error(`\n✗ ${failures.length} broken internal doc link(s):\n`);
  for (const f of failures) console.error("  " + f);
  console.error("");
  process.exit(1);
}
console.log(`✓ all internal doc links resolve (${mdFiles.length} files checked)`);
