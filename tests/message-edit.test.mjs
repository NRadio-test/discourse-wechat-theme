import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";

const theme = fs.readFileSync(new URL("../javascripts/discourse/api-initializers/wechat.gjs", import.meta.url), "utf8");
const start = theme.indexOf("class MessageEdit extends Component");
const end = theme.indexOf("\n    <template>", start);
const source = `${theme.slice(start, end)}\n}`.replace(/@tracked\s+/g, "").replace(/@action\s+/g, "");
function harness() {
  const requests = [], updates = [];
  let closed = 0;
  class Component { constructor(args) { this.args = args; } }
  const Class = new Function("Component", "ajax", "extractError", `${source}; return MessageEdit;`)(
    Component,
    (url, options) => new Promise((resolve, reject) => requests.push({ url, options, resolve, reject })),
    (error, fallback) => error.message || fallback,
  );
  const instance = new Class({ post: { id: 12, setProperties: (value) => updates.push(value) }, onClose: () => closed++ });
  return { instance, requests, updates, get closed() { return closed; },
    async load() { requests[0].resolve({ raw: "原始内容\n![图片](upload://sample.png)" }); await Promise.resolve(); },
  };
}

test("editing loads the original raw text without modifying the post", async () => {
  const h = harness();
  assert.equal(h.instance.disabled, true);
  await h.load();
  assert.equal(h.requests[0].url, "/posts/12.json");
  assert.equal(h.instance.raw, "原始内容\n![图片](upload://sample.png)");
  assert.equal(h.instance.disabled, false);
  assert.deepEqual(h.updates, []);
});

test("a save is single-flight and updates display only after server acceptance", async () => {
  const h = harness(); await h.load();
  h.instance.input({ target: { value: "修改后" } });
  const saving = h.instance.save();
  await h.instance.save();
  h.instance.cancel();
  h.instance.input({ target: { value: "不能覆盖正在保存的内容" } });
  assert.equal(h.requests.length, 2);
  assert.equal(h.closed, 0);
  assert.deepEqual(h.updates, []);
  assert.deepEqual(h.requests[1].options, { type: "PUT", data: { post: { raw: "修改后" } } });
  h.requests[1].resolve({ post: { raw: "修改后", cooked: "<p>修改后</p>" } });
  await saving;
  assert.equal(h.updates.length, 1);
  assert.equal(h.closed, 1);
});

test("server rejection preserves the edit and permits retry without changing the post", async () => {
  const h = harness(); await h.load();
  h.instance.raw = "尚未保存";
  const saving = h.instance.save();
  h.requests[1].reject(new Error("没有编辑权限")); await saving;
  assert.equal(h.instance.raw, "尚未保存");
  assert.equal(h.instance.error, "没有编辑权限");
  assert.equal(h.instance.saving, false);
  assert.deepEqual(h.updates, []);
  assert.equal(h.closed, 0);
});

test("cancel and blank edits never submit a request", async () => {
  const h = harness(); await h.load();
  h.instance.raw = "   "; await h.instance.save(); h.instance.cancel();
  assert.equal(h.requests.length, 1);
  assert.equal(h.closed, 1);
});

test("load failure cannot submit an empty replacement and still allows cancel", async () => {
  const h = harness();
  h.requests[0].reject(new Error("无法读取消息")); await Promise.resolve();
  assert.equal(h.instance.error, "无法读取消息");
  await h.instance.save(); h.instance.cancel();
  assert.equal(h.requests.length, 1);
  assert.equal(h.closed, 1);
});

test("a stale request never closes a later editor after its component is destroyed", async () => {
  const h = harness(); await h.load();
  const saving = h.instance.save(); h.instance.isDestroyed = true;
  h.requests[1].resolve({ post: { cooked: "<p>accepted</p>" } }); await saving;
  assert.equal(h.closed, 0);
  const loading = harness(); loading.instance.isDestroyed = true; await loading.load();
  assert.equal(loading.instance.raw, "");
});
