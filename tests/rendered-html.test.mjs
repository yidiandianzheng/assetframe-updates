import assert from "node:assert/strict";
import test from "node:test";

async function render() {
  const workerUrl = new URL("../dist/server/index.js", import.meta.url);
  workerUrl.searchParams.set("test", `${process.pid}-${Date.now()}`);
  const { default: worker } = await import(workerUrl.href);
  return worker.fetch(new Request("http://localhost/", { headers: { accept: "text/html" } }), { ASSETS: { fetch: async () => new Response("Not found", { status: 404 }) } }, { waitUntil() {}, passThroughOnException() {} });
}

test("renders the asset review studio", async () => {
  const response = await render();
  assert.equal(response.status, 200);
  const html = await response.text();
  assert.match(html, /<title>资产定帧｜视觉资产管理画布<\/title>/);
  assert.match(html, /视觉资产管理画布/);
  assert.match(html, /关系画布/);
  assert.match(html, /导入 CSV/);
  assert.match(html, /导出到 Excel/);
  assert.doesNotMatch(html, /codex-preview|react-loading-skeleton/);
});
