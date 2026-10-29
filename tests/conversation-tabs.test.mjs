import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";

// Exercise the real component methods with synthetic models. Compilation and
// browser checks separately verify Glimmer and the core store/router contracts.
const source = fs.readFileSync(new URL("../javascripts/discourse/api-initializers/wechat.gjs", import.meta.url), "utf8");
const helpers = source.slice(source.indexOf("const themeSettings"), source.indexOf("export default apiInitializer"));
const body = source.slice(source.indexOf("class Conversations extends Component"), source.indexOf("    <template>")).replace(/^\s*@service[^\n]+/gm, "").replaceAll("@tracked ", "").replaceAll("@action ", "") + "}";
function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
function harness({ path = "/top?period=daily", fetch, wide = true } = {}) {
  const calls = [], routes = [], frames = new Map(), removed = [];
  let nextFrame = 0;
  const window = { location: { pathname: path }, scrollY: 0, matchMedia: () => ({ matches: wide }),
    addEventListener() {}, removeEventListener(...args) { removed.push(args); }, scrollTo({ top }) { this.scrollY = top; } };
  class Base {}
  Base.prototype.router = { currentURL: path, on() {}, off() {} };
  Base.prototype.appEvents = { on() {}, off() {} };
  Base.prototype.store = { findFiltered(type, options) {
    calls.push(options);
    return fetch ? fetch(options.filter) : Promise.resolve({ topics: [{ id: options.filter }], canLoadMore: false });
  } };
  const Class = new Function("Component", "registerDestructor", "window", "document", "DiscourseURL", "requestAnimationFrame", "cancelAnimationFrame", `${helpers}; ${body}; return Conversations;`)(
    Base, (object, fn) => { object.destroy = fn; }, window, { body: { classList: { toggle() {} } } }, { routeTo(url) { routes.push(url); } },
    (fn) => { frames.set(++nextFrame, fn); return nextFrame; }, (id) => frames.delete(id)
  );
  const value = new Class();
  const element = { scrollTop: 0, addEventListener() {}, removeEventListener() {} };
  value.bindList(element);
  function flush() { const work = [...frames.values()]; frames.clear(); work.forEach((fn) => fn()); }
  flush();
  return { value, calls, routes, window, element, removed, flush,
    ready() { return Promise.all([...value.pendingLists.values()]); },
    choose(key, modifiers = {}) {
      let prevented = false;
      value.chooseTab({ key, url: key === "all" ? "/latest" : key === "top" ? "/top?period=daily" : "/tag/精华" },
        { button: 0, preventDefault() { prevented = true; }, ...modifiers });
      return prevented;
    }
  };
}

test("opening any discovery entry preloads three distinct lists with its visible list first", async () => {
  const h = harness({ path: "/latest" }); await h.ready();
  assert.equal(h.value.tab, "all");
  assert.deepEqual(h.calls.map((call) => call.filter), ["latest", "top", "tag/%E7%B2%BE%E5%8D%8E/l/latest"]);
  assert.deepEqual(h.calls[1].params, { period: "daily" });
  h.value.routeChanged(); await h.ready(); assert.equal(h.calls.length, 3);
});

test("repeated tab switches reuse cached lists and do not invoke core routing or requests", async () => {
  const h = harness(); await h.ready();
  for (const key of ["all", "featured", "top", "all", "all"]) {
    assert.equal(h.choose(key), true);
    assert.ok(h.value.model); assert.equal(Boolean(h.value.loading), false);
  }
  await h.ready(); assert.equal(h.calls.length, 3); assert.deepEqual(h.routes, []);
});

test("rapid switches deduplicate pending requests and slow responses stay in their own tabs", async () => {
  const pending = new Map(["top", "latest", "tag/%E7%B2%BE%E5%8D%8E/l/latest"].map((key) => [key, deferred()]));
  const h = harness({ fetch: (filter) => pending.get(filter).promise });
  h.choose("all"); h.choose("featured"); h.choose("all");
  await Promise.resolve(); assert.equal(h.calls.length, 3);
  pending.get("latest").resolve({ topics: [{ id: 21 }] });
  await h.value.pendingLists.get("all"); assert.equal(h.value.model.topics[0].id, 21);
  pending.get("top").resolve({ topics: [] });
  pending.get("tag/%E7%B2%BE%E5%8D%8E/l/latest").resolve({ topics: [{ id: 30 }] });
  await h.ready(); assert.equal(h.value.model.topics[0].id, 21);
  h.choose("top"); assert.equal(h.value.showingRecent, true); assert.equal(h.value.recentModel.topics[0].id, 21);
  h.choose("featured"); assert.equal(h.value.model.topics[0].id, 30);
});

test("a failed featured preload has its own retry and never falls back to the all list", async () => {
  let fail = true;
  const h = harness({ fetch: async (filter) => {
    if (filter.startsWith("tag/") && fail) throw new Error("network");
    return { topics: [{ id: filter }] };
  } });
  await h.ready(); assert.equal(h.value.error, false);
  h.choose("featured"); await h.ready(); assert.equal(h.value.error, true); assert.equal(h.value.model, undefined);
  fail = false; await h.value.load();
  assert.equal(h.value.error, false); assert.equal(h.value.model.topics[0].id.startsWith("tag/"), true);
});

test("top waits for its recent fallback and keeps fallback errors separate from daily data", async () => {
  const recent = deferred();
  const h = harness({ fetch: (filter) => filter === "latest" ? recent.promise : Promise.resolve({ topics: [] }) });
  await h.value.pendingLists.get("top"); assert.equal(h.value.loading, true);
  recent.reject(new Error("network")); await h.ready();
  assert.equal(h.value.error, false); assert.equal(h.value.recentError, true); assert.equal(h.value.loading, false);
});

test("real daily results never acquire an unrelated recent error", async () => {
  const h = harness({ fetch: async (filter) => {
    if (filter === "latest") throw new Error("network");
    return { topics: [{ id: 9 }] };
  } });
  await h.ready(); assert.equal(h.value.recentError, false); assert.equal(h.value.showingRecent, false);
});

test("refresh and message updates preserve visible rows until each fresh list is ready", async () => {
  const h = harness(); await h.ready(); const old = h.value.model;
  const response = deferred(); h.value.store.findFiltered = () => response.promise;
  const refresh = h.value.load();
  assert.equal(h.value.model, old); assert.equal(Boolean(h.value.loading), false);
  response.resolve({ topics: [{ id: 42 }] }); await refresh;
  assert.equal(h.value.model.topics[0].id, 42);
  let refreshed = 0; h.value.load = () => refreshed++;
  h.value.refreshAfterMessage(); assert.equal(refreshed, 1);
});

test("pagination remains attached to its tab while switching and after loading completes", async () => {
  const h = harness(); await h.ready(); h.choose("all");
  const model = h.value.model, more = deferred(); model.canLoadMore = true;
  model.loadMore = async () => { await more.promise; model.topics.push({ id: 80 }); };
  const loading = h.value.more(); h.choose("featured");
  assert.equal(Boolean(h.value.loadingMore), false);
  more.resolve(); await loading; h.choose("all");
  assert.equal(h.value.model, model); assert.equal(model.topics.at(-1).id, 80);
  assert.equal(h.calls.length, 3); assert.equal(h.value.loadingMore, false);
});

for (const wide of [true, false]) test(`${wide ? "desktop" : "mobile"} restores a separate scroll position for each tab`, async () => {
  const h = harness({ wide }); await h.ready();
  const target = wide ? h.element : h.window, key = wide ? "scrollTop" : "scrollY";
  target[key] = 320; h.choose("all"); h.value.restoreScroll(); h.flush(); assert.equal(target[key], 0);
  target[key] = 110; h.choose("top"); h.value.restoreScroll(); h.flush(); assert.equal(target[key], 320);
  h.choose("all"); h.value.restoreScroll(); h.flush(); assert.equal(target[key], 110);
});

test("modified clicks remain native; desktop topic tabs retain the conversation; personal pages exit normally", async () => {
  const h = harness({ path: "/t/topic/10/4" }); await h.ready();
  assert.equal(h.choose("all", { ctrlKey: true }), false); assert.equal(h.value.tab, "top");
  h.choose("all"); assert.deepEqual(h.routes, []); assert.equal(h.value.isTopic, true);
  h.value.router.currentURL = "/u/member/summary"; h.value.routeChanged();
  assert.equal(h.value.tab, "all"); h.choose("featured"); assert.deepEqual(h.routes, ["/tag/精华"]);
});

test("browser Back from a topic restores the locally selected discovery tab", async () => {
  const h = harness(); await h.ready(); h.choose("all");
  h.value.router.currentURL = "/t/topic/10/4"; h.value.routeChanged();
  h.value.router.currentURL = "/top?period=daily"; h.value.routeChanged();
  assert.equal(h.value.tab, "all"); assert.equal(h.calls.length, 3);
  h.value.router.currentURL = "/tag/精华"; h.value.routeChanged(); assert.equal(h.value.tab, "featured");
});

test("destroyed components ignore late responses and release scroll listeners", async () => {
  const response = deferred(); const h = harness({ fetch: () => response.promise });
  const ready = h.ready(), before = h.value.lists;
  h.value.destroy(); response.resolve({ topics: [{ id: 1 }] }); await ready;
  assert.equal(h.value.lists, before); assert.equal(h.value.listElement, null);
  assert.equal(h.value.pendingLists.size, 0); assert.ok(h.removed.length);
});
