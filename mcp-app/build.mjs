import { build } from "esbuild";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const entryFile = resolve(__dirname, "src/app.ts");
const cssFile = resolve(__dirname, "src/styles.css");
const outDir = resolve(__dirname, "dist");
const outHtml = resolve(outDir, "worktree-cleaner-app.html");

const result = await build({
  entryPoints: [entryFile],
  bundle: true,
  minify: true,
  format: "esm",
  target: ["es2022"],
  write: false,
  logLevel: "silent",
});

const jsBundle = result.outputFiles[0].text.replace(/<\/script>/gi, "<\\/script>");
const cssText = readFileSync(cssFile, "utf8");

const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Worktree Cleaner</title>
  <style>${cssText}</style>
</head>
<body>
  <div id="root"></div>
  <script type="module">${jsBundle}</script>
</body>
</html>
`;

mkdirSync(outDir, { recursive: true });
writeFileSync(outHtml, html, "utf8");
console.log(`Built single-file MCP App HTML: ${outHtml} (${(Buffer.byteLength(html, "utf8") / 1024).toFixed(1)} KiB)`);
