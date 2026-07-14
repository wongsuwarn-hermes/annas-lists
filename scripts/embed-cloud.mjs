import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const indexPath = path.join(root, "index.html");
const start = "<!-- ANNAs_CLOUD_MODULES_START -->";
const end = "<!-- ANNAs_CLOUD_MODULES_END -->";
const core = fs.readFileSync(path.join(root, "src", "sync-core.js"), "utf8").trim();
const client = fs.readFileSync(path.join(root, "src", "cloud-client.js"), "utf8").trim();
const config = JSON.parse(fs.readFileSync(path.join(root, "config", "public-config.json"), "utf8"));
const publicConfig = JSON.stringify({
  url: typeof config.url === "string" ? config.url : "",
  publishableKey: typeof config.publishableKey === "string" ? config.publishableKey : "",
  providers: {
    email: config.providers?.email === true,
    google: config.providers?.google === true
  }
}).replace(/</g, "\\u003c");
const block = `${start}\n<script id="annas-public-config" type="application/json">${publicConfig}</script>\n<script>\n${core}\n</script>\n<script>\n${client}\n</script>\n${end}`;
let html = fs.readFileSync(indexPath, "utf8");
const existing = new RegExp(`${start}[\\s\\S]*?${end}`);
if (existing.test(html)) {
  html = html.replace(existing, block);
} else {
  const marker = '<script>\n"use strict";';
  if (!html.includes(marker)) throw new Error("Could not locate Anna's Lists application script");
  html = html.replace(marker, `${block}\n${marker}`);
}
fs.writeFileSync(indexPath, html);
console.log(`Embedded cloud modules in ${indexPath}`);
