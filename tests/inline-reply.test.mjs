// Run: node --test tests/inline-reply.test.mjs
// The theme class is read from this repository. By default its collaborator is
// an original, minimal CONTRACT adapter below, not Discourse's implementation.
// Optional: DISCOURSE_SOURCE=/path/to/discourse loads the actual local upstream
// component for a compatibility check. No upstream source is vendored here.
// Neither mode starts Ember or replaces rendered UI / real-device testing.
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";

const themePath = new URL("../javascripts/discourse/api-initializers/wechat.gjs", import.meta.url);
const themeSource = fs.readFileSync(themePath, "utf8");
const upstreamPath = process.env.DISCOURSE_SOURCE
  ? path.join(process.env.DISCOURSE_SOURCE, "frontend/discourse/app/components/docked-composer.gjs")
  : null;

function extractClass(source, name) {
  const start = source.indexOf(`class ${name} extends Component`);
  const end = source.indexOf("\n    <template>", start) >= 0
    ? source.indexOf("\n    <template>", start)
    : source.indexOf("\n  <template>", start);
  assert.ok(start >= 0 && end > start, `Cannot extract ${name}: update the test loader for the new GJS shape`);
  return `${source.slice(start, end)}\n}`
    .replace(/^\s*@service \w+;\s*$/gm, "")
    .replace(/@tracked\s+/g, "")
    .replace(/@action\s+/g, "");
}

const inlineSource = extractClass(themeSource, "InlineReply");
const upstreamSource = upstreamPath ? extractClass(fs.readFileSync(upstreamPath, "utf8"), "DockedComposer") : null;

// Original test adapter for only the contract used by InlineReply:
// - content and upload arguments are passed to onSubmit;
// - truthy acknowledgement clears the editor and its saved text;
// - falsy/rejected acknowledgement retains content;
// - the caller controls the submitting/disabled state;
// - Enter behavior respects the configured mode and composition state.
// Deliberately absent: Glimmer rendering, Uppy, real DOM event dispatch, editor
// internals and browser focus behavior. These require integration/device QA.
function composerContract(Component) {
  return class ComposerContractAdapter extends Component {
    constructor(args) {
      super(args);
      this.reply = "";
      this.uploads = [];
    }

    setReply(text) {
      this.reply = text ?? "";
      if (this.reply === "") this.keyValueStore.remove(this.args.draftKey);
      else this.keyValueStore.set({ key: this.args.draftKey, value: this.reply });
    }

    setupEditor({ textarea }) {
      textarea.addEventListener("keydown", (event) => {
        if (event.key !== "Enter" || event.isComposing) return;
        const shortcut = event.ctrlKey || event.metaKey;
        const plain = !shortcut && !event.shiftKey && !event.altKey;
        const requestsSend = this.args.submitOnEnter === false ? shortcut : plain;
        if (requestsSend) {
          event.preventDefault();
          event.stopPropagation();
          void this.submit();
        }
      });
    }

    async submit() {
      if (this.args.disabled || this.args.isSubmitting) return;
      if (!this.reply.trim() && this.uploads.length === 0) return;
      try {
        const accepted = await this.args.onSubmit({ raw: this.reply, uploads: this.uploads, inProgressUploadsCount: 0 });
        if (accepted) {
          this.setReply("");
          this.uploads = [];
        }
      } catch (error) {
        this.args.onError(error);
      }
    }
  };
}

console.log(`Composer collaborator: ${upstreamSource ? "local upstream source (optional compatibility mode)" : "original contract adapter (not Discourse core)"}`);

function makeHarness() {
  const pendingReplies = new Map();
  const values = new Map();
  const handlers = new Map();
  const requests = [];
  const created = [];
  const events = [];
  const appEvents = {
    on(name, target, fn) {
      const list = handlers.get(name) || [];
      list.push({ target, fn });
      handlers.set(name, list);
    },
    off(name, target, fn) {
      handlers.set(name, (handlers.get(name) || []).filter((h) => h.target !== target || h.fn !== fn));
    },
    trigger(name, value) {
      events.push({ name, value });
      for (const h of handlers.get(name) || []) h.fn.call(h.target, value);
    },
  };
  const keyValueStore = {
    get: (key) => values.get(key) ?? null,
    set: ({ key, value }) => values.set(key, value),
    remove: (key) => values.delete(key),
  };
  const services = {
    currentUser: { id: 7 }, appEvents, keyValueStore,
    store: {
      createRecord(type, attributes) {
        assert.equal(type, "post");
        created.push(attributes);
        return {
          ...attributes, id: 99, post_number: 2,
          save() {
            return new Promise((resolve, reject) => requests.push({ resolve, reject }));
          },
        };
      },
    },
  };
  class Component {
    constructor(args) { this.args = args; Object.assign(this, services); }
  }
  const controller = { model: { id: 1 }, quoteState: { clear() {} } };
  const api = { container: { lookup() { return controller; } } };
  const InlineReply = new Function(
    "Component", "pendingReplies", "api", "registerDestructor", "window", "document", "getUploadMarkdown", "extractError", "DiscourseURL",
    `${inlineSource}; return InlineReply;`
  )(
    Component, pendingReplies, api, (instance, callback) => { instance.cleanup = callback; },
    { innerWidth: 1200, removeEventListener() {} },
    { body: { style: { removeProperty() {} } } },
    (upload) => upload.markdown, (error) => error.message, { routeTo() {} }
  );
  const DockedComposer = upstreamSource ? new Function(
    "Component", "trackedArray", "schedule", "popupAjaxError",
    `${upstreamSource}; return DockedComposer;`
  )(
    Component, (items = []) => [...items], (_queue, callback) => callback(),
    (error) => { throw error; }
  ) : composerContract(Component);

  function create(topicId = 1) {
    const instance = new InlineReply({ topic: { id: topicId, details: { can_create_post: true } } });
    instance.lockInput = () => {};
    // Stream routing is covered in browser QA, outside these submission checks.
    instance.showSentPost = () => {};
    return instance;
  }
  function destroy(instance) {
    instance.isDestroying = true;
    instance.cleanup();
    instance.isDestroyed = true;
  }
  function dock(inline, { raw = "", uploads = [], enter = true } = {}) {
    const core = new DockedComposer({
      draftKey: inline.draftKey, submitOnEnter: enter,
      onSubmit: (payload) => inline.submit(payload),
      get isSubmitting() { return inline.sending; },
      get disabled() { return inline.sending; },
      onError: (error) => inline.reportError(error),
    });
    core.setReply(raw);
    core.uploads = [...uploads];
    const listeners = new Map();
    core.setupEditor({ textarea: {
      tagName: "TEXTAREA", focus() {},
      addEventListener(name, handler) { listeners.set(name, handler); },
      removeEventListener(name) { listeners.delete(name); },
    } });
    return { core, listeners };
  }
  function keydown(inline, listeners, properties = {}) {
    const event = {
      key: "Enter", keyCode: 13, isComposing: false,
      stopped: false, prevented: false,
      stopPropagation() { this.stopped = true; },
      preventDefault() { this.prevented = true; },
      ...properties,
    };
    // Models the parent-capture-before-input ordering; not a real DOM dispatch.
    inline.guardInput(event);
    if (!event.stopped) listeners.get("keydown")(event);
    return event;
  }
  function succeed(index = 0) { requests[index].resolve({ responseJson: { action: "enqueued" } }); }
  return { create, destroy, dock, keydown, succeed, requests, created, events, pendingReplies, values, keyValueStore, controller };
}

test("inline edit preserves the reply draft and blocks sending it until edit closes", async () => {
  const h = makeHarness(), a = h.create(); a.element = {};
  const { core } = h.dock(a, { raw: "未发出的回复", uploads: [{ markdown: "图片" }] });
  const request = { post: { id: 4, topic_id: 1, post_type: 1, can_edit: true } };
  a.selectEdit(request);
  assert.equal(request.handled, true);
  assert.equal(a.editPost, request.post);
  await core.submit();
  assert.equal(h.requests.length, 0);
  a.closeEdit();
  assert.equal(core.reply, "未发出的回复");
  assert.equal(core.uploads.length, 1);
  assert.equal(h.values.get(a.draftKey), "未发出的回复");
});

test("inline edit respects permissions, topic scope and an existing edit", () => {
  const h = makeHarness(), a = h.create(); a.element = {};
  for (const fields of [{ can_edit: false }, { topic_id: 2 }, { post_type: 4 }, { is_localized: true }]) {
    const request = { post: { id: 4, topic_id: 1, post_type: 1, can_edit: true, ...fields } };
    a.selectEdit(request); assert.equal(request.handled, undefined);
  }
  const first = { post: { id: 4, topic_id: 1, post_type: 1, can_edit: true } };
  a.selectEdit(first);
  const second = { post: { ...first.post, id: 5 } }; a.selectEdit(second);
  assert.equal(second.handled, true);
  assert.equal(a.editPost.id, 4);
});

test("rapid clicks share one synchronous submission lock", async () => {
  const h = makeHarness(), a = h.create();
  h.values.set(a.draftKey, "原消息");
  const payload = { raw: "原消息", uploads: [], inProgressUploadsCount: 0 };
  const first = a.submit(payload);
  assert.equal(await a.submit(payload), false);
  assert.equal(h.requests.length, 1);
  h.succeed();
  assert.equal(await first, true);
  assert.equal(a.sending, false);
  assert.equal(h.pendingReplies.size, 0);
});

for (const newerDraft of [false, true]) {
  test(`A → B → A retains the lock and ${newerDraft ? "preserves newer A text" : "clears only the sent A draft"}`, async () => {
    const h = makeHarness(), a = h.create();
    const { core } = h.dock(a, { raw: "原消息" });
    const first = core.submit();
    h.destroy(a);
    const b = h.create(2);
    h.values.set(b.draftKey, "B草稿");
    const a2 = h.create();
    assert.equal(a2.sending, true);
    assert.equal(await a2.submit({ raw: "原消息", uploads: [], inProgressUploadsCount: 0 }), false);
    assert.equal(h.requests.length, 1);
    if (newerDraft) h.values.set(a2.draftKey, "后来写的新草稿");
    h.succeed();
    await first; // Also waits for the collaborator's post-submit clearing path.
    assert.equal(h.values.get(a2.draftKey), newerDraft ? "后来写的新草稿" : undefined);
    assert.equal(core.reply, "原消息", "destroyed owner's collaborator must receive false and skip clearing");
    assert.equal(h.values.get(b.draftKey), "B草稿");
    assert.equal(a2.sending, false);
    assert.equal(a2.composerRevision, 1);
    assert.equal(h.pendingReplies.size, 0);
  });
}

test("failure after remount unlocks the current A and retains its draft", async () => {
  const h = makeHarness(), a = h.create();
  h.values.set(a.draftKey, "失败保留");
  const first = a.submit({ raw: "失败保留", uploads: [], inProgressUploadsCount: 0 });
  h.destroy(a);
  const a2 = h.create();
  h.requests[0].reject(new Error("网络失败"));
  assert.equal(await first, false);
  assert.equal(a2.sending, false);
  assert.equal(h.values.get(a2.draftKey), "失败保留");
  assert.equal(a2.error, "网络失败");
  assert.equal(a2.composerRevision, 0);
});

test("normal same-instance success acknowledges editor clearing without remounting", async () => {
  const h = makeHarness(), a = h.create();
  const { core } = h.dock(a, { raw: "成功消息" });
  const first = core.submit();
  h.succeed();
  await first;
  assert.equal(core.reply, "");
  assert.deepEqual(core.uploads, []);
  assert.equal(a.composerRevision, 0);
  assert.equal(a.sending, false);
  assert.equal(h.values.has(a.draftKey), false);
});

test("image-only input with a null saved text draft still clears uploads on success", async () => {
  const h = makeHarness(), a = h.create();
  const { core } = h.dock(a, { uploads: [{ markdown: "![图片](upload://sample.png)" }] });
  assert.equal(h.keyValueStore.get(a.draftKey), null);
  const first = core.submit();
  assert.equal(h.created[0].raw, "![图片](upload://sample.png)");
  h.succeed();
  await first;
  const finished = h.events.find((event) => event.name === "wx:reply-send-finished");
  assert.equal(finished.value.clearOwner, true);
  assert.deepEqual(core.uploads, []);
  assert.equal(a.composerRevision, 0);
  assert.equal(h.values.has(a.draftKey), false);
});

test("busy reply and selection quote are handled without the old editor fallback", () => {
  const h = makeHarness(), a = h.create();
  a.sending = true;
  a.element = {};
  const request = { topic: { id: 1 }, post: { id: 4, topic_id: 1, post_type: 1 } };
  a.selectReply(request);
  assert.equal(request.handled, true);
  const quote = { post: request.post };
  a.selectQuote(quote);
  assert.equal(quote.handled, true);
  assert.equal(a.replyContext, null);
});

test("busy input blocks file paste, drop and keyboard-triggered upload clicks", () => {
  const h = makeHarness(), a = h.create();
  a.sending = true;
  for (const type of ["paste", "drop", "click"]) {
    const event = {
      type, target: { closest() { return {}; } },
      preventDefault() { this.prevented = true; },
      stopPropagation() { this.stopped = true; },
    };
    a.guardUpload(event);
    assert.equal(event.prevented, true, type);
    assert.equal(event.stopped, true, type);
  }
});

test("IME isComposing, composition lifecycle, and legacy keyCode 229 never submit", async () => {
  const h = makeHarness(), a = h.create();
  const { listeners } = h.dock(a, { raw: "中文候选" });
  for (const properties of [{ isComposing: true }, { keyCode: 229 }]) {
    const event = h.keydown(a, listeners, properties);
    assert.equal(event.stopped, true);
    assert.equal(event.prevented, false, "native IME candidate selection must remain available");
    assert.equal(h.requests.length, 0);
  }
  a.startComposition();
  const composing = h.keydown(a, listeners);
  assert.equal(composing.stopped, true);
  assert.equal(h.requests.length, 0);
  a.endComposition();
  const regular = h.keydown(a, listeners);
  assert.equal(regular.prevented, true);
  assert.equal(h.requests.length, 1, "after IME ends, the collaborator's Enter handler must still submit");
  h.succeed();
  await Promise.resolve();
  await Promise.resolve();
});

test("mobile Enter and desktop Shift+Enter do not submit, mobile Ctrl+Enter does", async () => {
  const h = makeHarness(), a = h.create();
  const desktop = h.dock(a, { raw: "第一行" });
  h.keydown(a, desktop.listeners, { shiftKey: true });
  assert.equal(h.requests.length, 0);
  const mobile = h.dock(a, { raw: "第二行", enter: false });
  h.keydown(a, mobile.listeners);
  assert.equal(h.requests.length, 0);
  h.keydown(a, mobile.listeners, { ctrlKey: true });
  assert.equal(h.requests.length, 1);
  h.succeed();
  await Promise.resolve();
  await Promise.resolve();
});
