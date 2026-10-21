// Run from the theme repository: node --test tests/topic-groups.test.mjs
// Runs the real component's JS behavior with service boundaries replaced.
// It does not post to a forum and does not replace Ember compilation/browser QA.
import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";

const path = new URL("../javascripts/discourse/api-initializers/topic-groups.gjs", import.meta.url);
const source = fs.readFileSync(path, "utf8");
const start = source.indexOf("class TopicGroupModal extends Component");
const end = source.indexOf("\n  <template>", start);
assert.ok(start >= 0 && end > start);
const componentSource = `${source.slice(start, end)}\n}`
  .replace(/^\s*@service \w+;\s*$/gm, "")
  .replace(/@tracked\s+/g, "")
  .replace(/@action\s+/g, "");
const uploadFields = ["id", "url", "short_url", "original_filename", "thumbnail_width", "thumbnail_height", "filesize"];
const draftUpload = new Function("UPLOAD_FIELDS", `${source.slice(source.indexOf("function draftUpload"), start)}; return draftUpload;`)(uploadFields);

function harness({ category = { id: 4, read_restricted: false, canCreateTopic: true }, allowed = true } = {}) {
  const pending = new Map(), values = new Map(), handlers = new Map(), requests = [], created = [], events = [], routes = [];
  const appEvents = {
    on(name, target, callback) { handlers.set(target, { name, callback }); },
    off(_name, target) { handlers.delete(target); },
    trigger(name, data) {
      events.push({ name, data });
      for (const [target, listener] of [...handlers]) if (listener.name === name) listener.callback.call(target, data);
    },
  };
  const keyValueStore = {
    get: (key) => values.get(key) ?? null,
    set: ({ key, value }) => values.set(key, value),
    remove: (key) => values.delete(key),
  };
  const services = {
    appEvents, keyValueStore,
    currentUser: { id: 7, can_create_topic: allowed },
    site: { isReadOnly: false },
    siteSettings: { min_topic_title_length: 2, max_topic_title_length: 80, min_first_post_length: 1 },
    store: {
      createRecord(type, attributes) {
        assert.equal(type, "post");
        created.push(attributes);
        const post = { ...attributes, save() { return new Promise((resolve, reject) => requests.push({ post, resolve, reject })); } };
        return post;
      },
    },
  };
  class Component { constructor(args) { this.args = args; Object.assign(this, services); } }
  class UppyUpload {
    inProgressUploads = [];
    uploading = false;
    processing = false;
    constructor(_owner, config) { this.config = config; }
    setup() {}
    teardown() { this.closed = true; }
    cancelSingleUpload({ fileId }) { this.inProgressUploads = this.inProgressUploads.filter((upload) => upload.id !== fileId); }
  }
  const Modal = new Function("Component", "pendingTopics", "UppyUpload", "getOwner", "registerDestructor", "Category", "draftUpload", "getUploadMarkdown", "extractError", "DiscourseURL", `${componentSource}; return TopicGroupModal;`)(
    Component, pending, UppyUpload, () => ({}), (instance, cleanup) => { instance.cleanup = cleanup; },
    { asyncFindById: async () => category }, draftUpload,
    (upload) => `![${upload.original_filename}](${upload.short_url})`,
    (error) => error.message, { routeTo: (url) => routes.push(url) },
  );
  async function create(categoryId = 4) {
    const modal = new Modal({ model: { categoryId }, closeModal() { modal.wasClosed = true; } });
    await Promise.resolve(); await Promise.resolve();
    return modal;
  }
  function destroy(modal) { modal.isDestroying = true; modal.cleanup(); modal.isDestroyed = true; }
  function success(index = 0) {
    Object.assign(requests[index].post, { id: 91, topic_id: 21, post_number: 1 });
    requests[index].resolve({ responseJson: { action: "create_post" } });
  }
  return { create, destroy, success, values, requests, created, events, routes, pending, services };
}

function type(modal, title, body = "") {
  modal.changeTitle({ target: { value: title } });
  if (body) modal.changeBody({ target: { value: body } });
}

test("a title alone starts a regular public topic without category/tag UI parameters", async () => {
  const h = harness(), modal = await h.create();
  type(modal, "今天聊聊");
  const promise = modal.submit();
  assert.equal(h.created[0].title, "今天聊聊");
  assert.equal(h.created[0].raw, "今天聊聊");
  assert.equal(h.created[0].category, 4);
  assert.equal(h.created[0].archetype, "regular");
  assert.equal(h.created[0].category_id, undefined);
  assert.equal(h.created[0].tags, undefined);
  h.success();
  assert.equal(await promise, true);
  assert.equal(h.values.has(modal.draftKey), false);
  assert.equal(modal.wasClosed, true);
  assert.deepEqual(h.routes, ["/t/topic/21/1"]);
});

test("rapid submits and replacement modal share one in-flight lock", async () => {
  const h = harness(), first = await h.create(); type(first, "重复点击");
  const promise = first.submit();
  assert.equal(await first.submit(), false);
  assert.equal(first.beforeClose(), false);
  h.destroy(first);
  const second = await h.create();
  assert.equal(second.sending, true);
  assert.equal(await second.submit(), false);
  assert.equal(h.requests.length, 1);
  h.success(); await promise;
  assert.equal(second.title, "");
  assert.equal(second.sending, false);
  assert.equal(h.values.has(second.draftKey), false);
  assert.equal(h.pending.size, 0);
});

test("closing keeps title, body and completed images; reopening restores them", async () => {
  const h = harness(), first = await h.create(); type(first, "图片草稿", "先写几句");
  first.uploader.config.uploadDone({ id: 5, original_filename: "test.png", short_url: "upload://test.png", url: "/uploads/test.png", thumbnail_width: 120, thumbnail_height: 80 });
  first.close(); h.destroy(first);
  const second = await h.create();
  assert.equal(second.title, "图片草稿");
  assert.equal(second.body, "先写几句");
  assert.equal(second.uploads[0].id, 5);
  assert.equal(second.uploader.config.validateUploadedFilesOptions.bypassNewUserRestriction, false);
  assert.equal(second.uploader.config.validateUploadedFilesOptions.imagesOnly, true);
});

test("server rejection keeps the same draft and permits an explicit retry", async () => {
  const h = harness(), modal = await h.create(); type(modal, "失败保留", "完整内容");
  const before = h.values.get(modal.draftKey), promise = modal.submit();
  h.requests[0].reject(new Error("请求过于频繁，请稍后重试"));
  assert.equal(await promise, false);
  assert.equal(modal.body, "完整内容");
  assert.equal(h.values.get(modal.draftKey), before);
  assert.match(modal.error, /请求过于频繁/);
  assert.equal(modal.sending, false);
  assert.equal(h.pending.size, 0);
  assert.equal(h.requests.length, 1);
});

test("queued acceptance clears draft, shows review state and never navigates to a fake post", async () => {
  const h = harness(), modal = await h.create(); type(modal, "待审核话题");
  const promise = modal.submit();
  h.requests[0].resolve({ responseJson: { action: "enqueued" } });
  await promise;
  assert.match(modal.notice, /审核/);
  assert.equal(modal.title, "");
  assert.equal(h.values.has(modal.draftKey), false);
  assert.equal(h.routes.length, 0);
  assert.equal(await modal.submit(), false);
  assert.equal(h.requests.length, 1);
  modal.uploader.config.uploadDone({ id: 8, original_filename: "new.png", short_url: "upload://new.png", url: "/uploads/new.png" });
  assert.equal(JSON.parse(h.values.get(modal.draftKey)).uploads[0].id, 8);
});

test("private, unknown and forbidden categories fail closed", async () => {
  for (const category of [null, { id: 4, read_restricted: true, canCreateTopic: true }, { id: 4, canCreateTopic: true }, { id: 4, read_restricted: false, canCreateTopic: false }]) {
    const h = harness({ category }), modal = await h.create(); type(modal, "无权创建");
    assert.equal(await modal.submit(), false);
    assert.equal(h.created.length, 0);
    assert.ok(modal.categoryError);
  }
  const h = harness(), modal = await h.create(0); type(modal, "缺省分类");
  assert.equal(await modal.submit(), false);
  assert.equal(h.created.length, 0);
});

test("account permission and read-only mode prevent creation", async () => {
  const h = harness({ allowed: false }), modal = await h.create(); type(modal, "权限检查");
  assert.equal(await modal.submit(), false);
  const h2 = harness(), modal2 = await h2.create(); h2.services.site.isReadOnly = true; type(modal2, "只读检查");
  assert.equal(await modal2.submit(), false);
});

test("image upload blocks submit and closing until complete; image markdown is submitted", async () => {
  const h = harness(), modal = await h.create(); type(modal, "图片话题");
  modal.uploader.inProgressUploads = [{ id: "in-flight", fileName: "test.png" }];
  assert.equal(await modal.submit(), false);
  assert.equal(modal.beforeClose(), false);
  modal.uploader.inProgressUploads = [];
  modal.uploader.config.uploadDone({ id: 5, original_filename: "test.png", short_url: "upload://test.png", url: "/uploads/test.png" });
  const promise = modal.submit();
  assert.equal(h.created[0].raw, "![test.png](upload://test.png)");
  h.success(); await promise;
});

test("title length and server-required first-post length are checked without losing the draft", async () => {
  const h = harness(), modal = await h.create(); type(modal, "短");
  assert.equal(await modal.submit(), false);
  assert.match(modal.error, /2–80/);
  type(modal, "合适标题"); h.services.siteSettings.min_first_post_length = 10;
  assert.equal(await modal.submit(), false);
  assert.match(modal.error, /开场内容/);
  assert.equal(h.created.length, 0);
});

test("opening time and idle pauses are not counted as typing; IME shortcut does not submit", async () => {
  const h = harness(), modal = await h.create();
  modal.lastInputAt = Date.now() - 20000;
  modal.changeTitle({ target: { value: "输入计时" } });
  assert.equal(modal.typingMs, 0);
  modal.shortcut({ key: "Enter", isComposing: true, ctrlKey: true, preventDefault() { throw new Error("must not intercept IME"); } });
  assert.equal(h.created.length, 0);
});

test("in-app route aborts legacy editor; direct URL redirects to a real page; guest only logs in", async () => {
  const initializer = source.slice(source.indexOf('export default apiInitializer("1.0", (api) => {')).replace("export default ", "");
  let currentUser = { id: 7 }, ModalRoute, ComposerService, openEvent, opened = 0, logins = 0, redirects = [], nativeCalls = [], scheduled = [], finishRedirect, activeModal = false;
  class TopicGroupModal {}
  const modal = { show(component, opts) { assert.equal(component, TopicGroupModal); assert.equal(opts.model.categoryId, 4); opened++; activeModal = true; } };
  const api = {
    getCurrentUser: () => currentUser,
    onAppEvent(name, callback) { assert.equal(name, "wx:new-topic"); openEvent = callback; },
    modifyClass(name, decorate) {
      if (name === "route:new-topic") ModalRoute = decorate(class {});
      else if (name === "service:composer") ComposerService = decorate(class { open(opts) { nativeCalls.push(opts); } });
      else throw new Error(`Unexpected class ${name}`);
    },
    container: { lookup(name) {
      if (name === "service:modal") return modal;
      if (name === "service:site-settings") return { default_composer_category: 4 };
      if (name === "route:application") return { send(action) { assert.equal(action, "showLogin"); logins++; } };
      throw new Error(`Unexpected lookup ${name}`);
    } },
  };
  let inConversation = true;
  new Function("apiInitializer", "TopicGroupModal", "settings", "defaultHomepage", "CREATE_TOPIC", "next", "document", initializer)((_version, callback) => callback(api), TopicGroupModal, { default_topic_category_id: 0 }, () => "top", "createTopic", (callback) => scheduled.push(callback), { body: { classList: { contains: () => inConversation } } });
  const route = new ModalRoute();
  route.router = { replaceWith(name) { redirects.push(name); return { followRedirects: () => new Promise((resolve) => { finishRedirect = resolve; }) }; } };
  let aborted = false;
  route.beforeModel({ from: {}, abort() { aborted = true; } });
  assert.equal(aborted, true); assert.equal(opened, 1);
  route.beforeModel({ from: null });
  assert.equal(opened, 1, "do not open while the destination route is still loading");
  assert.equal(scheduled.length, 0);
  finishRedirect(); await Promise.resolve(); await Promise.resolve();
  assert.deepEqual(redirects, ["discovery.top"]);
  assert.equal(opened, 1, "transition resolution must not open before route teardown finishes");
  assert.equal(scheduled.length, 1);
  // The destination closes transient UI in its current runloop. The next
  // runloop opens our modal after that teardown, as in core's new-topic route.
  activeModal = false;
  scheduled.shift()();
  assert.equal(opened, 2); assert.equal(activeModal, true);
  const composer = new ComposerService(); composer.router = { currentRouteName: "discovery.top" };
  await composer.open({ action: "createTopic" });
  assert.equal(opened, 3); assert.equal(nativeCalls.length, 0);
  await composer.open({ action: "edit" });
  await composer.open({ action: "privateMessage" });
  composer.router.currentRouteName = "admin.dashboard";
  await composer.open({ action: "createTopic" });
  assert.deepEqual(nativeCalls.map((call) => call.action), ["edit", "privateMessage", "createTopic"]);
  inConversation = false; composer.router.currentRouteName = "discovery.category";
  await composer.open({ action: "createTopic", categoryId: 99 });
  assert.deepEqual(nativeCalls.at(-1), { action: "createTopic", categoryId: 99 }, "private/category context remains native instead of silently becoming public");
  assert.equal(opened, 3);
  currentUser = null; openEvent();
  assert.equal(logins, 1); assert.equal(opened, 3);
});


test("IME pre-edit counts actual observed activity once, without idle, upload or pasted text time", async () => {
  const h = harness(), modal = await h.create();
  const realNow = Date.now; let now = 10000;
  Date.now = () => now;
  try {
    modal.compositionStart();
    now += 200; modal.compositionUpdate();
    modal.changeTitle({ target: { value: "拼" } });
    assert.equal(modal.typingMs, 200, "same-timestamp input is not double-counted");
    now += 300; modal.compositionUpdate();
    now += 100; modal.compositionEnd();
    modal.changeTitle({ target: { value: "拼音" } });
    assert.equal(modal.typingMs, 600);
    now += 5000; modal.compositionStart();
    now += 120; modal.compositionUpdate();
    modal.resetTypingActivity();
    now += 300; modal.changeBody({ target: { value: "开始聊" } });
    assert.equal(modal.typingMs, 720, "blurred/upload intervals are excluded");
    now += 600; modal.changeBody({ target: { value: "粘贴的内容" }, inputType: "insertFromPaste" });
    assert.equal(modal.typingMs, 720, "paste is not typing time");
    modal.beforeClose(); now += 20000;
    modal.changeBody({ target: { value: "草稿继续" } });
    assert.equal(modal.typingMs, 720, "closed draft idle is excluded");
  } finally { Date.now = realNow; }
});
