// Run from the repository root: node --test tests/message-actions.test.mjs
// Exercise the actual theme class's gesture and lifecycle logic. Ember outlet
// rendering, native permission buttons and touch-device behavior need browser QA.
import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";

const theme = fs.readFileSync(new URL("../javascripts/discourse/api-initializers/wechat.gjs", import.meta.url), "utf8");
const start = theme.indexOf("class MessageActions extends Component");
const end = theme.indexOf("\n    <template>", start);
assert.ok(start > 0 && end > start);
const source = `${theme.slice(start, end)}\n}`
  .replace(/^\s*@service \w+;\s*$/gm, "")
  .replace(/@tracked\s+/g, "")
  .replace(/@action\s+/g, "");

function eventSource() {
  const listeners = new Map();
  return {
    listeners,
    addEventListener(type, handler) {
      if (!listeners.has(type)) listeners.set(type, new Set());
      listeners.get(type).add(handler);
    },
    removeEventListener(type, handler) { listeners.get(type)?.delete(handler); },
    emit(type, event) { for (const fn of [...(listeners.get(type) || [])]) fn(event); },
    count() { return [...listeners.values()].reduce((n, set) => n + set.size, 0); },
  };
}

function harness() {
  let time = 0, sequence = 0;
  let selection = null, copyFailure = false;
  const copied = [];
  const timers = new Map(), frames = new Map();
  const document = { ...eventSource(), activeElement: null, querySelector: () => ({ getBoundingClientRect: () => ({ top: 720 }) }) };
  const window = {
    ...eventSource(), innerWidth: 360, innerHeight: 800,
    visualViewport: { ...eventSource(), width: 360, height: 800, offsetTop: 0, offsetLeft: 0 },
    getSelection: () => selection,
    setTimeout(fn, wait) { const id = ++sequence; timers.set(id, { fn, at: time + wait }); return id; },
    clearTimeout(id) { timers.delete(id); },
    requestAnimationFrame(fn) { const id = ++sequence; frames.set(id, fn); return id; },
    cancelAnimationFrame(id) { frames.delete(id); },
  };
  class Component { constructor(args) { this.args = args; this.router = { currentURL: "/t/test/1/2" }; } }
  const Class = new Function("Component", "registerDestructor", "window", "document", "clipboardCopy", `let activeMessageActions = null; let messageActionSequence = 0; ${source}; return MessageActions;`)(
    Component, (instance, cleanup) => { instance.cleanup = cleanup; }, window, document,
    (text) => { copied.push(text); return copyFailure ? Promise.reject(new Error("blocked")) : Promise.resolve(); }
  );

  class Element {
    constructor(tag, classes = [], parent = null) {
      this.tagName = tag.toUpperCase();
      this.classes = new Set(classes);
      this.classList = { add: (...names) => names.forEach((name) => this.classes.add(name)), remove: (...names) => names.forEach((name) => this.classes.delete(name)), contains: (name) => this.classes.has(name) };
      this.parent = parent;
      this.children = [];
      parent?.children.push(this);
      this.dataset = {};
      this.properties = new Map();
      this.style = { setProperty: (key, value) => this.properties.set(key, value) };
      this.isConnected = true;
      Object.assign(this, eventSource());
    }
    matches(selector) {
      return selector.split(",").some((part) => {
        part = part.trim();
        if (part.startsWith(".")) return this.classes.has(part.slice(1));
        if (part === "[contenteditable]") return !!this.contenteditable;
        return this.tagName.toLowerCase() === part;
      });
    }
    closest(selector) { for (let el = this; el; el = el.parent) if (el.matches(selector)) return el; return null; }
    contains(target) { for (let el = target; el; el = el.parent) if (el === this) return true; return false; }
    querySelector(selector) {
      if (selector === ".post__contents > .cooked") return this.bubble;
      const scan = (el) => { for (const child of el.children) { if (child.matches(selector)) return child; const found = scan(child); if (found) return found; } };
      return scan(this) || null;
    }
    querySelectorAll() { return (this.buttons || []).filter((element) => !element.disabled); }
    getBoundingClientRect() { return this.rect || { left: 70, top: 300, right: 310, bottom: 350, width: 240, height: 50 }; }
    getClientRects() { return this.hidden ? [] : [this.getBoundingClientRect()]; }
    focus() { document.activeElement = this; document.emit("focusin", { target: this }); }
  }

  function create(id = 1) {
    const instance = new Class({ outletArgs: { post: { id, post_number: id } } });
    for (const key of Object.getOwnPropertyNames(Class.prototype)) {
      if (key !== "constructor" && typeof Object.getOwnPropertyDescriptor(Class.prototype, key)?.value === "function") instance[key] = instance[key].bind(instance);
    }
    const post = new Element("div", ["topic-post"]);
    const bubble = new Element("div", ["cooked"], post);
    bubble.innerText = "消息正文\n第二段";
    post.bubble = bubble;
    const text = new Element("p", [], bubble);
    const root = new Element("div", ["wx-message-actions"], post);
    const trigger = new Element("button", ["wx-message-actions-trigger"], root);
    const menu = new Element("div", ["wx-message-actions-popover"], root);
    menu.rect = { width: 300, height: 160 };
    const reply = new Element("button", ["post-action-menu__reply"], menu);
    const bookmark = new Element("button", ["post-action-menu__bookmark"], menu);
    menu.buttons = [reply, bookmark];
    instance.setup(root);
    return { instance, post, bubble, text, root, trigger, menu, reply, bookmark };
  }
  function advance(ms) {
    time += ms;
    for (const [id, timer] of [...timers]) if (timer.at <= time) { timers.delete(id); timer.fn(); }
  }
  function frame() { for (const [id, fn] of [...frames]) { frames.delete(id); fn(); } }
  function pointer(target, overrides = {}) {
    return { target, pointerType: "touch", pointerId: 1, isPrimary: true, button: 0, clientX: 160, clientY: 340, ...overrides };
  }
  function key(target, overrides = {}) {
    return { target, prevented: false, stopped: false, preventDefault() { this.prevented = true; }, stopPropagation() { this.stopped = true; }, ...overrides };
  }
  return {
    create, advance, frame, pointer, key, Element, document, window, timers, frames, copied,
    selectText(node) { selection = { isCollapsed: false, anchorNode: node, focusNode: node, toString: () => "已选中的文字" }; },
    failCopy() { copyFailure = true; },
  };
}

test("short tap and touch scrolling never open the menu", () => {
  const h = harness(), { instance, text } = h.create();
  instance.pointerDown(h.pointer(text));
  h.advance(150);
  instance.pointerEnd(h.pointer(text));
  h.advance(500);
  assert.equal(instance.isOpen, false);
  instance.pointerDown(h.pointer(text));
  instance.pointerMove(h.pointer(text, { clientY: 360 }));
  h.advance(500);
  assert.equal(instance.isOpen, false);
  assert.equal(h.document.count(), 0);
});

test("a stationary hold opens once and suppresses only its follow-up text click", () => {
  const h = harness(), { instance, text, bubble } = h.create();
  instance.pointerDown(h.pointer(text));
  h.advance(479);
  assert.equal(instance.isOpen, false);
  h.advance(1);
  assert.equal(instance.isOpen, true);
  const click = h.key(text);
  instance.suppressHeldClick(click);
  assert.equal(click.prevented, true);
  const imageClick = h.key(new h.Element("img", [], bubble));
  instance.suppressHeldClick(imageClick);
  assert.equal(imageClick.prevented, false);
});

for (const tag of ["a", "video", "audio", "button", "textarea", "iframe"]) {
  test(`${tag} keeps native click, hold and context menu behavior`, () => {
    const h = harness(), { instance, bubble } = h.create();
    const target = new h.Element(tag, [], bubble);
    instance.pointerDown(h.pointer(target));
    h.advance(600);
    const context = h.key(target, { clientX: 160, clientY: 340 });
    instance.contextMenu(context);
    assert.equal(instance.isOpen, false);
    assert.equal(context.prevented, false);
  });
}

test("an image tap opens normally but an image hold opens message actions instead", () => {
  const h = harness(), { instance, bubble } = h.create();
  const lightbox = new h.Element("a", ["lightbox"], bubble);
  const image = new h.Element("img", [], lightbox);
  instance.pointerDown(h.pointer(image));
  h.advance(120);
  instance.pointerEnd(h.pointer(image));
  const tap = h.key(image);
  instance.suppressHeldClick(tap);
  assert.equal(tap.prevented, false);
  assert.equal(instance.isOpen, false);
  instance.pointerDown(h.pointer(image));
  h.advance(480);
  assert.equal(instance.isOpen, true);
  const heldClick = h.key(image);
  instance.suppressHeldClick(heldClick);
  assert.equal(heldClick.prevented, true);
  instance.pointerDown(h.pointer(image));
  instance.pointerEnd(h.pointer(image));
  const nextTap = h.key(image);
  instance.suppressHeldClick(nextTap);
  assert.equal(nextTap.prevented, false, "a separate tap must not inherit hold suppression");
});

test("right click and keyboard open the existing menu; Escape restores trigger focus", () => {
  const h = harness(), { instance, text, trigger, reply } = h.create();
  const context = h.key(text, { clientX: 160, clientY: 340 });
  instance.contextMenu(context);
  h.frame();
  assert.equal(context.prevented, true);
  assert.equal(h.document.activeElement, reply);
  const escape = h.key(reply, { key: "Escape" });
  instance.documentKeyDown(escape);
  assert.equal(instance.isOpen, false);
  assert.equal(h.document.activeElement, trigger);
  const shortcut = h.key(trigger, { key: "F10", shiftKey: true });
  instance.postKeyDown(shortcut);
  h.frame();
  assert.equal(instance.isOpen, true);
  assert.equal(shortcut.prevented, true);
});

test("only one message menu is open; outside click and page scroll close it", () => {
  const h = harness(), a = h.create(1), b = h.create(2);
  a.instance.openMenu();
  b.instance.openMenu();
  assert.equal(a.instance.isOpen, false);
  assert.equal(b.instance.isOpen, true);
  h.document.emit("pointerdown", { target: new h.Element("div") });
  assert.equal(b.instance.isOpen, false);
  a.instance.openMenu();
  h.document.emit("scroll", { target: h.document });
  assert.equal(a.instance.isOpen, false);
});

test("nested native menus retain their anchor and internal scrolling remains usable", () => {
  const h = harness(), { instance, menu, bookmark } = h.create();
  instance.openMenu();
  instance.menuClick({ target: bookmark });
  h.frame();
  assert.equal(instance.isOpen, true);
  const nativePopup = new h.Element("div", ["fk-d-menu"]);
  const child = new h.Element("button", [], nativePopup);
  h.document.emit("pointerdown", { target: child });
  h.document.emit("scroll", { target: menu });
  assert.equal(instance.isOpen, true);
});

test("reply action closes the shell after dispatch without preventing the native action", () => {
  const h = harness(), { instance, reply } = h.create();
  instance.openMenu();
  const click = h.key(reply);
  instance.menuClick(click);
  assert.equal(click.prevented, false);
  h.frame();
  assert.equal(instance.isOpen, false);
});

test("arrow navigation skips disabled/hidden native buttons and Tab out closes the shell", () => {
  const h = harness(), { instance, reply, bookmark, menu } = h.create();
  const disabled = new h.Element("button", [], menu);
  disabled.disabled = true;
  const hidden = new h.Element("button", [], menu);
  hidden.hidden = true;
  menu.buttons = [reply, disabled, hidden, bookmark];
  instance.openMenu({ focus: true });
  h.frame();
  const right = h.key(reply, { key: "ArrowRight" });
  instance.menuKeyDown(right);
  assert.equal(h.document.activeElement, bookmark);
  assert.equal(right.prevented, true);
  h.document.emit("focusin", { target: new h.Element("button") });
  assert.equal(instance.isOpen, false);
});

test("destroying a holding/open message removes timers, listeners and selection state", () => {
  const h = harness(), a = h.create();
  a.instance.pointerDown(h.pointer(a.text));
  a.instance.cleanup();
  h.advance(600);
  assert.equal(a.instance.isOpen, false);
  assert.equal(h.timers.size, 0);
  assert.equal(h.document.count(), 0);
  assert.equal(a.post.classes.has("wx-message-pressing"), false);
  const b = h.create(2);
  b.instance.openMenu();
  b.instance.cleanup();
  h.frame();
  assert.equal(h.document.count(), 0);
  assert.equal(h.window.count(), 0);
  assert.equal(h.window.visualViewport.count(), 0);
  assert.equal(h.frames.size, 0);
});

test("nested reply previews and missing post DOM retain the native menu", () => {
  const h = harness(), { instance } = h.create();
  instance.args.outletArgs.state = { nestedReplyView: true };
  assert.equal(instance.enabled, false);
  instance.setup(new h.Element("div"));
  assert.equal(instance.ready, false);
  assert.equal(instance.isClosed, false, "native yielded controls must not be hidden when enhancement cannot mount");
  assert.equal(instance.triggerHidden, true);
  assert.equal(h.document.count(), 0);
});

test("an existing text selection keeps its native hold and context menu", () => {
  const h = harness(), { instance, text } = h.create();
  h.selectText(text);
  instance.pointerDown(h.pointer(text));
  h.advance(600);
  const context = h.key(text, { clientX: 160, clientY: 340 });
  instance.contextMenu(context);
  assert.equal(context.prevented, false);
  assert.equal(instance.isOpen, false);
});

test("copy body delegates to the native clipboard helper and reports permission failures", async () => {
  const h = harness(), { instance } = h.create();
  instance.openMenu();
  await instance.copyBody();
  assert.deepEqual(h.copied, ["消息正文\n第二段"]);
  assert.equal(instance.copyLabel, "已复制正文");
  h.failCopy();
  await instance.copyBody();
  assert.equal(instance.copyError, true);
  assert.equal(instance.copying, false);
});


test("repeated instances of the same post have distinct accessible menu IDs", () => {
  const h = harness(), a = h.create(1), b = h.create(1);
  assert.notEqual(a.instance.menuId, b.instance.menuId);
  assert.match(a.instance.menuId, /^wx-message-menu-1-\d+$/);
});
