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

function harness({ coarsePointer = false } = {}) {
  let time = 0, sequence = 0;
  let copyFailure = false;
  const selection = {
    isCollapsed: true, anchorNode: null, focusNode: null, text: "",
    toString() { return this.text; },
    removeAllRanges() { this.isCollapsed = true; this.anchorNode = this.focusNode = null; this.text = ""; },
    addRange(range) { this.isCollapsed = false; this.anchorNode = this.focusNode = range.node; this.text = range.node.innerText; },
  };
  const copied = [];
  const closedMenus = [];
  let clearedQuoteStates = 0;
  const timers = new Map(), frames = new Map();
  const document = {
    ...eventSource(), activeElement: null,
    querySelector: () => ({ getBoundingClientRect: () => ({ top: 720 }) }),
    createRange: () => ({ selectNodeContents(node) { this.node = node; } }),
  };
  const window = {
    ...eventSource(), innerWidth: 360, innerHeight: 800,
    visualViewport: { ...eventSource(), width: 360, height: 800, offsetTop: 0, offsetLeft: 0 },
    matchMedia: () => ({ matches: coarsePointer }),
    getSelection: () => selection,
    setTimeout(fn, wait) { const id = ++sequence; timers.set(id, { fn, at: time + wait }); return id; },
    clearTimeout(id) { timers.delete(id); },
    requestAnimationFrame(fn) { const id = ++sequence; frames.set(id, fn); return id; },
    cancelAnimationFrame(id) { frames.delete(id); },
  };
  const api = { container: { lookup(name) {
    if (name === "service:menu") return { close: (identifier) => { closedMenus.push(identifier); } };
    if (name === "controller:topic") return { quoteState: { clear: () => clearedQuoteStates++ } };
    throw new Error(`Unexpected service: ${name}`);
  } } };
  class Component { constructor(args) { this.args = args; this.router = { currentURL: "/t/test/1/2" }; } }
  const Class = new Function("Component", "registerDestructor", "window", "document", "clipboardCopy", "api", `let activeMessageActions = null; let activeTextSelection = null; let messageActionSequence = 0; ${source}; return MessageActions;`)(
    Component, (instance, cleanup) => { instance.cleanup = cleanup; }, window, document,
    (text) => { copied.push(text); return copyFailure ? Promise.reject(new Error("blocked")) : Promise.resolve(); }, api
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
    create, advance, frame, pointer, key, Element, document, window, timers, frames, copied, closedMenus, selection,
    get clearedQuoteStates() { return clearedQuoteStates; },
    selectText(node) { Object.assign(selection, { isCollapsed: false, anchorNode: node, focusNode: node, text: "已选中的文字" }); },
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

for (const tag of ["video", "audio", "button", "textarea", "iframe"]) {
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
  assert.equal(a.post.dataset.wxMessageActions, undefined);
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

test("desktop text selection keeps its native context menu", () => {
  const h = harness(), { instance, text } = h.create();
  h.selectText(text);
  instance.pointerDown(h.pointer(text, { pointerType: "mouse" }));
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
  assert.equal(instance.copyLabel, "已复制");
  assert.equal(instance.isOpen, false);
  instance.openMenu();
  h.failCopy();
  await instance.copyBody();
  assert.equal(instance.copyError, true);
  assert.equal(instance.copying, false);
  assert.equal(instance.isOpen, true, "a failed copy keeps the selection fallback accessible");
});

test("touch menus clear late collapsed, whitespace and menu selections", () => {
  const h = harness(), { instance, text, menu } = h.create();
  instance.pointerDown(h.pointer(text));
  for (const node of [text, menu]) {
    Object.assign(h.selection, { anchorNode: node, focusNode: node, isCollapsed: true, text: "" });
    h.document.emit("selectionchange", {});
    assert.equal(h.selection.anchorNode, null);
  }
  h.advance(480);
  Object.assign(h.selection, { anchorNode: text, focusNode: text, isCollapsed: false, text: "  " });
  h.document.emit("selectionchange", {});
  assert.equal(h.selection.anchorNode, null);
  assert.equal(instance.isOpen, true);
  instance.closeMenu();
  assert.equal(h.document.count(), 0);
});

test("native selection starts are cancelled only for touch message/menu controls", () => {
  const h = harness({ coarsePointer: true }), { instance, text, reply, bubble } = h.create();
  for (const target of [text, reply]) {
    const event = h.key(target);
    instance.selectionStart(event);
    assert.equal(event.prevented, true);
  }
  const input = h.key(new h.Element("textarea", [], bubble));
  instance.selectionStart(input);
  assert.equal(input.prevented, false);
  instance.selectText();
  const explicit = h.key(text);
  instance.selectionStart(explicit);
  assert.equal(explicit.prevented, false);
  instance.endTextSelection();
  instance.setPointerMode("mouse");
  const desktop = h.key(text);
  instance.selectionStart(desktop);
  assert.equal(desktop.prevented, false);
});

test("selection guard preserves outside text, editable fields and explicit selection", () => {
  const h = harness({ coarsePointer: true }), { instance, bubble } = h.create();
  instance.openMenu();
  for (const node of [new h.Element("p"), new h.Element("textarea", [], bubble)]) {
    h.selectText(node);
    h.document.emit("selectionchange", {});
    assert.equal(h.selection.anchorNode, node);
  }
  instance.selectText();
  h.document.emit("selectionchange", {});
  assert.equal(h.selection.anchorNode, bubble);
  assert.equal(instance.isSelecting, true);
});

test("copy success clears even a collapsed range and dismisses its menu", async () => {
  const h = harness({ coarsePointer: true }), { instance, text } = h.create();
  instance.openMenu();
  Object.assign(h.selection, { anchorNode: text, focusNode: text, isCollapsed: true });
  await instance.copyBody();
  assert.equal(h.selection.anchorNode, null);
  assert.equal(instance.isOpen, false);
  assert.equal(h.document.count(), 0);
});

test("a delayed copy cannot close a reopened menu or remove explicit selection", async () => {
  const h = harness({ coarsePointer: true }), { instance, bubble } = h.create();
  instance.openMenu();
  const first = instance.copyBody();
  instance.closeMenu();
  instance.openMenu();
  await first;
  assert.equal(instance.isOpen, true);
  assert.equal(instance.copyState, "");
  const second = instance.copyBody();
  instance.selectText();
  await second;
  assert.equal(instance.isSelecting, true);
  assert.equal(h.selection.anchorNode, bubble);
});

test("cancelled gestures release their selection listener; destruction ignores pending copies", async () => {
  const h = harness(), { instance, text } = h.create();
  instance.pointerDown(h.pointer(text));
  instance.pointerMove(h.pointer(text, { clientY: 400 }));
  assert.equal(h.document.count(), 0);
  h.selectText(text);
  h.document.emit("selectionchange", {});
  assert.equal(h.selection.anchorNode, text);
  instance.openMenu();
  const copying = instance.copyBody();
  instance.cleanup();
  await copying;
  assert.equal(h.document.count(), 0);
  assert.equal(h.timers.size, 0);
  assert.equal(instance.isOpen, false);
});


test("repeated instances of the same post have distinct accessible menu IDs", () => {
  const h = harness(), a = h.create(1), b = h.create(1);
  assert.notEqual(a.instance.menuId, b.instance.menuId);
  assert.match(a.instance.menuId, /^wx-message-menu-1-\d+$/);
});

test("touch links open on a short tap and use the message menu only after a hold", () => {
  const h = harness(), { instance, bubble } = h.create();
  const link = new h.Element("a", [], bubble);
  instance.pointerDown(h.pointer(link));
  h.advance(120);
  instance.pointerEnd(h.pointer(link));
  const tap = h.key(link);
  instance.suppressHeldClick(tap);
  assert.equal(tap.prevented, false);
  instance.pointerDown(h.pointer(link));
  h.advance(480);
  const heldClick = h.key(link);
  instance.suppressHeldClick(heldClick);
  assert.equal(instance.isOpen, true);
  assert.equal(heldClick.prevented, true);
  instance.closeMenu();
  instance.pointerDown(h.pointer(link, { pointerType: "mouse", button: 2 }));
  const desktopContext = h.key(link);
  instance.contextMenu(desktopContext);
  assert.equal(desktopContext.prevented, false);
  assert.equal(instance.isOpen, false);
});

test("a coarse pointer is protected before its first press and mouse input restores selection", () => {
  const h = harness({ coarsePointer: true }), { instance, post, text } = h.create();
  assert.equal(post.dataset.wxPointerMode, "touch");
  instance.pointerDown(h.pointer(text, { pointerType: "mouse" }));
  assert.equal(post.dataset.wxPointerMode, "mouse");
});

test("touch hold clears a stray native selection and never opens the menu twice", () => {
  const h = harness(), { instance, text } = h.create();
  h.selectText(text);
  instance.pointerDown(h.pointer(text));
  assert.equal(h.selection.isCollapsed, true);
  h.advance(480);
  assert.equal(instance.isOpen, true);
  const positioning = instance.positionFrame;
  const nativeContext = h.key(text, { pointerType: "touch" });
  instance.contextMenu(nativeContext);
  assert.equal(nativeContext.prevented, true);
  assert.equal(instance.positionFrame, positioning, "native contextmenu must not re-open a completed hold");
  assert.ok(h.closedMenus.length > 0);
  assert.ok(h.closedMenus.every((id) => id === "post-text-selection-toolbar"));
});

test("a context menu after finger movement stays cancelled and does not become native selection", () => {
  const h = harness(), { instance, text } = h.create();
  instance.pointerDown(h.pointer(text));
  instance.pointerMove(h.pointer(text, { clientY: 380 }));
  const nativeContext = h.key(text, { pointerType: "touch" });
  instance.contextMenu(nativeContext);
  assert.equal(nativeContext.prevented, true);
  assert.equal(instance.isOpen, false);
});

test("a cancelled touch cannot open a delayed native context menu", () => {
  const h = harness(), { instance, text } = h.create();
  instance.pointerDown(h.pointer(text));
  instance.pointerEnd(h.pointer(text, { type: "pointercancel" }));
  h.advance(600);
  const context = h.key(text, { pointerType: "touch" });
  instance.contextMenu(context);
  assert.equal(context.prevented, true);
  assert.equal(instance.isOpen, false);
});

test("keyboard context menus preserve explicit selection, desktop selected text and links", () => {
  const h = harness(), { instance, text, bubble } = h.create();
  instance.selectText();
  const selecting = h.key(text, { key: "F10", shiftKey: true });
  instance.postKeyDown(selecting);
  assert.equal(selecting.prevented, false);
  assert.equal(instance.isSelecting, true);
  assert.equal(instance.isOpen, false);
  instance.endTextSelection();
  h.selectText(text);
  const desktopSelection = h.key(text, { key: "ContextMenu" });
  instance.postKeyDown(desktopSelection);
  assert.equal(desktopSelection.prevented, false);
  h.selection.removeAllRanges();
  const link = new h.Element("a", [], bubble);
  const linkContext = h.key(link, { key: "F10", shiftKey: true });
  instance.postKeyDown(linkContext);
  assert.equal(linkContext.prevented, false);
  assert.equal(instance.isOpen, false);
});

test("select text closes the message menu and admits only native selection until Done", () => {
  const h = harness(), { instance, text, post, bubble } = h.create();
  instance.pointerDown(h.pointer(text));
  h.advance(480);
  instance.selectText();
  assert.equal(instance.isOpen, false);
  assert.equal(instance.isSelecting, true);
  assert.equal(post.dataset.wxSelecting, "true");
  assert.equal(h.selection.anchorNode, bubble);
  instance.pointerDown(h.pointer(text));
  h.advance(600);
  const nativeContext = h.key(text, { pointerType: "touch" });
  instance.contextMenu(nativeContext);
  assert.equal(nativeContext.prevented, false);
  assert.equal(instance.isOpen, false);
  instance.endTextSelection();
  assert.equal(instance.isSelecting, false);
  assert.equal(h.selection.isCollapsed, true);
  assert.equal(h.document.count(), 0);
});

test("selection mode survives scrolling, closes outside/Escape and cleans up on destruction", () => {
  const h = harness(), a = h.create();
  a.instance.selectText();
  h.document.emit("scroll", { target: h.document });
  assert.equal(a.instance.isSelecting, true);
  h.document.emit("pointerdown", { target: new h.Element("div") });
  assert.equal(a.instance.isSelecting, false);
  a.instance.selectText();
  const escape = h.key(a.text, { key: "Escape" });
  h.document.emit("keydown", escape);
  assert.equal(a.instance.isSelecting, false);
  assert.equal(escape.prevented, true);
  a.instance.selectText();
  a.instance.cleanup();
  assert.equal(h.document.count(), 0);
  assert.equal(h.selection.isCollapsed, true);
  assert.equal(a.post.dataset.wxSelecting, undefined);
});

test("only one native selection mode exists, and opening another message exits it", () => {
  const h = harness(), a = h.create(1), b = h.create(2);
  a.instance.selectText();
  b.instance.selectText();
  assert.equal(a.instance.isSelecting, false);
  assert.equal(b.instance.isSelecting, true);
  a.instance.openMenu();
  assert.equal(b.instance.isSelecting, false);
  assert.equal(a.instance.isOpen, true);
});

// Exercise the real narrowly-scoped core override, including an in-flight
// fast-edit permission check that resolves after entering touch mode.
const quoteHookStart = theme.indexOf('api.modifyClass("component:post-text-selection"');
const quoteHookEnd = theme.indexOf('api.registerValueTransformer("post-menu-buttons"', quoteHookStart);
assert.ok(quoteHookStart > 0 && quoteHookEnd > quoteHookStart);
function quoteHarness() {
  const h = harness(), post = h.create();
  let Hook, resolveFastEdit;
  class Core {
    shown = false;
    hidden = 0;
    failure = null;
    computeCurrentCooked() { return post.bubble; }
    async showToolbar() {
      await new Promise((resolve) => { resolveFastEdit = resolve; });
      if (this.failure) throw this.failure;
      this.shown = true;
    }
    async hideToolbar() { this.hidden++; this.shown = false; }
  }
  new Function("api", theme.slice(quoteHookStart, quoteHookEnd))({ modifyClass: (_, factory) => { Hook = factory(Core); } });
  return { ...h, ...post, hook: new Hook(), finishFastEdit: () => resolveFastEdit() };
}

test("core quoting toolbar stays available to desktop selection and skips enhanced touch selection", async () => {
  const h = quoteHarness();
  assert.equal(h.hook.computeCurrentCooked(), h.bubble);
  const desktop = h.hook.showToolbar(h.bubble);
  h.finishFastEdit();
  await desktop;
  assert.equal(h.hook.shown, true);
  h.post.dataset.wxPointerMode = "touch";
  assert.equal(h.hook.computeCurrentCooked(), undefined);
  await h.hook.showToolbar(h.bubble);
  assert.equal(h.hook.shown, false);
  delete h.post.dataset.wxPointerMode;
  h.post.dataset.wxSelecting = "true";
  assert.equal(h.hook.computeCurrentCooked(), undefined);
});

test("a quote toolbar awaiting fast-edit checks closes if the post switches to touch mode", async () => {
  const h = quoteHarness();
  const pending = h.hook.showToolbar(h.bubble);
  h.post.dataset.wxPointerMode = "touch";
  h.finishFastEdit();
  await pending;
  assert.equal(h.hook.shown, false);
  assert.equal(h.hook.hidden, 1);
});

test("only obsolete touch selections absorb core selection errors", async () => {
  const h = quoteHarness();
  h.hook.failure = new Error("selection disappeared");
  const stale = h.hook.showToolbar(h.bubble);
  h.post.dataset.wxSelecting = "true";
  h.finishFastEdit();
  await stale;
  assert.equal(h.hook.shown, false);
  delete h.post.dataset.wxSelecting;
  const genuine = h.hook.showToolbar(h.bubble);
  h.finishFastEdit();
  await assert.rejects(genuine, /selection disappeared/);
});

test("core class rerenders preserve theme touch, open and text-selection state", async () => {
  const h = quoteHarness();
  h.instance.pointerDown(h.pointer(h.text));
  h.advance(480);
  // Glimmer replaces the core-owned class attribute when a post updates.
  h.post.classes.clear();
  h.post.classes.add("topic-post");
  h.post.classes.add("regular");
  assert.equal(h.post.dataset.wxMessageActions, "true");
  assert.equal(h.post.dataset.wxPointerMode, "touch");
  assert.equal(h.post.dataset.wxMenuOpen, "true");
  assert.equal(h.hook.computeCurrentCooked(), undefined);
  await h.hook.showToolbar(h.bubble);
  assert.equal(h.hook.shown, false);
  h.instance.selectText();
  h.post.classes.clear();
  h.post.classes.add("topic-post");
  assert.equal(h.post.dataset.wxSelecting, "true");
  assert.equal(h.post.dataset.wxMenuOpen, undefined);
  assert.equal(h.hook.computeCurrentCooked(), undefined);
  h.instance.cleanup();
  assert.equal(h.post.dataset.wxMessageActions, undefined);
  assert.equal(h.post.dataset.wxPointerMode, undefined);
  assert.equal(h.post.dataset.wxSelecting, undefined);
  assert.equal(h.post.dataset.wxMenuOpen, undefined);
});
