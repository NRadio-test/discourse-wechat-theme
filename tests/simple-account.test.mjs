// Exercise the real initializer and link model; no production requests or writes.
import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";

const source = fs.readFileSync(new URL("../javascripts/discourse/api-initializers/simple-account.gjs", import.meta.url), "utf8");
const userLinks = new Function(`${source.slice(source.indexOf("function userLinks"), source.indexOf("class AccountMenu"))}; return userLinks;`)();
const user = { id: 7, path: "/u/member" };

test("public profile links never include another person's private account destinations", () => {
  assert.deepEqual(userLinks(user, false).map((link) => link.href), ["/u/member/summary", "/u/member/activity/topics"]);
  assert.deepEqual(userLinks(user, true).slice(-2).map((link) => link.href), ["/u/member/notifications", "/u/member/preferences/notifications"]);
  assert.equal(userLinks(null, false).length, 0);
});

test("hidden and inactive profiles do not expose activity; owners retain their settings", () => {
  for (const state of [{ profile_hidden: true }, { inactive: true }]) {
    assert.deepEqual(userLinks({ ...user, ...state }, false), []);
    assert.deepEqual(userLinks({ ...user, ...state }, true).map((link) => link.label), ["消息", "设置"]);
  }
});

function harness() {
  const classes = {}, outlets = [], redirects = [];
  const router = { currentURL: "/latest", replaceWith(...args) { redirects.push(args); return "transition"; } };
  const originalPanel = class NativeAccount {};
  const top = ["all-notifications", "replies", "likes", "messages", "bookmarks", "review-queue", "other-notifications"].map((id, position) => ({ id, position }));
  const bottom = [{ id: "profile", panelComponent: originalPanel, position: top.length }];
  class BaseMenu { get topTabs() { return top; } get bottomTabs() { return bottom; } }
  class AccountMenu {}
  class ProfileNavigation {}
  class ProfileSummary {}
  const api = {
    onPageChange() {},
    modifyClass(name, decorate) { classes[name] = decorate(name === "component:user-menu/menu" ? BaseMenu : class {}); },
    renderInOutlet(name) { outlets.push(name); },
    container: { lookup(name) { assert.equal(name, "service:router"); return router; } },
  };
  new Function("apiInitializer", "AccountMenu", "ProfileNavigation", "ProfileSummary", "SimpleSettings", source.slice(source.indexOf("export default apiInitializer")).replace("export default ", ""))((_v, callback) => callback(api), AccountMenu, ProfileNavigation, ProfileSummary, class {});
  return { classes, router, redirects, outlets, top, bottom, AccountMenu, originalPanel };
}

test("obsolete draft and bookmark URLs return to topics without touching stored drafts", () => {
  const h = harness();
  for (const name of ["route:userActivity.drafts", "route:userActivity.bookmarks"]) {
    const route = new h.classes[name](); route.router = h.router;
    assert.equal(route.beforeModel(), "transition");
  }
  assert.deepEqual(h.redirects, [["discovery.latest"], ["discovery.latest"]]);
});

test("profile and activity landing routes redirect using the already-authorized user model", () => {
  const h = harness();
  for (const name of ["route:user.index", "route:userActivity.index"]) {
    const route = new h.classes[name](); route.router = h.router;
    route.modelFor = (routeName) => { assert.equal(routeName, "user"); return user; };
    route.beforeModel();
  }
  assert.deepEqual(h.redirects, [["user.summary", user], ["userActivity.topics", user]]);
});

test("consolidation keeps notifications, private messages and review queue with keyboard positions", () => {
  const h = harness(), menu = new h.classes["component:user-menu/menu"]();
  assert.deepEqual(menu.topTabs.map((tab) => tab.id), ["all-notifications", "messages", "review-queue"]);
  assert.deepEqual(menu.topTabs.map((tab) => tab.position), [0, 1, 2]);
  assert.equal(menu.bottomTabs[0].panelComponent, h.AccountMenu);
  assert.equal(menu.bottomTabs[0].position, 3);
});

test("external links to retired preference tabs land on notifications without changing settings", () => {
  const h = harness();
  for (const name of ["interface", "tracking", "navigation-menu", "calendar-subscriptions"]) {
    const route = new h.classes[`route:preferences.${name}`](); route.router = h.router;
    route.modelFor = (routeName) => { assert.equal(routeName, "user"); return user; };
    route.beforeModel();
  }
  assert.deepEqual(h.redirects, Array(4).fill(["preferences.notifications", user]));
});

test("cached core tabs and profile panel are restored on admin routes, including return trips", () => {
  const h = harness(), menu = new h.classes["component:user-menu/menu"]();
  menu.topTabs; menu.bottomTabs;
  h.router.currentURL = "/admin/dashboard";
  assert.deepEqual(menu.topTabs.map((tab) => tab.position), [0, 1, 2, 3, 4, 5, 6]);
  assert.equal(menu.bottomTabs[0].panelComponent, h.originalPanel);
  assert.equal(menu.bottomTabs[0].position, 7);
  h.router.currentURL = "/u/member/summary";
  assert.equal(menu.bottomTabs[0].panelComponent, h.AccountMenu);
  assert.equal(menu.bottomTabs[0].position, 3);
});

const shell = fs.readFileSync(new URL("../javascripts/discourse/api-initializers/wechat.gjs", import.meta.url), "utf8");
const pageKind = new Function("featuredUrl", "featuredKey", `${shell.slice(shell.indexOf("function pageKind"), shell.indexOf("export default apiInitializer"))}; return pageKind;`)("/tag/精华", "精华");
test("personal pages use the chat shell without theming administration or unrelated routes", () => {
  for (const url of ["/u/member", "/u/member/summary", "/u/member/activity/topics?foo=bar", "/u/member/preferences/security"]) assert.equal(pageKind(url), "user");
  assert.equal(pageKind("/t/topic/14/2"), "topic");
  assert.equal(pageKind("/latest"), "all");
  assert.equal(pageKind("/top?period=daily"), "top");
  for (const url of ["/admin/users/member", "/review", "/categories"]) assert.equal(pageKind(url), "other");
});
