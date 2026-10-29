import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";

const account = fs.readFileSync(new URL("../javascripts/discourse/api-initializers/simple-account.gjs", import.meta.url), "utf8");
const settingsClass = account.slice(account.indexOf("class SimpleSettings"), account.indexOf("  <template>", account.indexOf("class SimpleSettings"))).replace(/^\s*@service[^\n]+/gm, "").replaceAll("@tracked ", "").replaceAll("@action ", "") + "}";
const SimpleSettings = new Function("Component", `return ${settingsClass}`)(class {});
function settings(save) {
  const value = new SimpleSettings();
  const user = { id: 7, user_option: { like_notification_frequency: 2, notify_on_linked_posts: true }, save,
    set(key, v) { this.user_option[key.split(".")[1]] = v; } };
  value.args = { outletArgs: { model: user } }; value.currentUser = { id: 7 };
  return { value, user };
}

test("settings save only the changed option, lock concurrent changes and reject unsupported fields", async () => {
  let resolve; const calls = [];
  const { value, user } = settings((fields) => { calls.push(fields); return new Promise((r) => { resolve = r; }); });
  const save = value.persist("like_notification_frequency", 1);
  await value.persist("notify_on_linked_posts", false);
  assert.deepEqual(calls, [["like_notification_frequency"]]);
  assert.equal(user.user_option.notify_on_linked_posts, true);
  resolve(); await save;
  assert.equal(value.message, "已保存");
  await value.persist("email", "fake@example.test");
  await value.persist("like_notification_frequency", -1);
  assert.equal(calls.length, 1);
});

test("a failed save rolls back the option and another person's settings cannot be changed", async () => {
  const { value, user } = settings(() => Promise.reject(new Error("network")));
  await value.persist("notify_on_linked_posts", false);
  assert.equal(user.user_option.notify_on_linked_posts, true);
  assert.equal(value.busy, false); assert.equal(value.error, true);
  value.currentUser.id = 8;
  user.save = () => assert.fail("must not save another user's settings");
  await value.persist("notify_on_linked_posts", false);
  await value.saveSchedule();
});

const navSource = fs.readFileSync(new URL("../javascripts/discourse/api-initializers/chat-navigation.gjs", import.meta.url), "utf8");
function navigation() {
  const jumps = [], stored = [], subscriptions = [], removed = [];
  let frame;
  const document = { addEventListener() {}, removeEventListener() {}, getElementById() { return null; }, querySelector() { return null; } };
  const window = { innerHeight: 800, addEventListener() {}, removeEventListener() {} };
  class Base { constructor(args) { this.args = args; } }
  Base.prototype.appEvents = { on(...args) { subscriptions.push(args); }, off(...args) { removed.push(args); } };
  Base.prototype.currentUser = { id: 7 };
  Base.prototype.keyValueStore = { set(value) { stored.push(value); } };
  const body = navSource.slice(navSource.indexOf("function postNumber"), navSource.indexOf("class NavigationOutlet")).replace(/<template>[\s\S]*?<\/template>/g, "").replace(/^\s*@service[^\n]+/gm, "").replaceAll("@tracked ", "").replaceAll("@action ", "");
  const Class = new Function("Component", "registerDestructor", "requestAnimationFrame", "cancelAnimationFrame", "DiscourseURL", "document", "window", `${body}; return ChatNavigation;`)(Base, (obj, fn) => { obj.destroy = fn; }, (fn) => { frame = fn; return 1; }, () => {}, { routeTo(url) { jumps.push(url); } }, document, window);
  const value = new Class({ topic: { id: 10, highest_post_number: 30, urlForPostNumber(n) { return `/t/topic/10/${n}`; } } });
  return { value, jumps, stored, document, subscriptions, removed, flush() { frame(); } };
}

test("reading saves only this topic under the current account and teardown releases event handlers", () => {
  const h = navigation();
  h.value.readPost({ post: { topic_id: 11, post_number: 5 } });
  h.value.readPost({ post: { topic_id: 10, post_number: -3 } });
  h.value.readPost({ post: { topic_id: 10, post_number: 12 } });
  assert.deepEqual(h.stored, [{ key: "wx-read-7-10", value: 12 }]);
  h.value.destroy(); assert.equal(h.subscriptions.length, h.removed.length);
});

test("reply jump preserves a return point and ignores cross-topic or invalid targets", () => {
  const h = navigation();
  for (const args of [{ topicId: 11, from: 12, to: 2 }, { topicId: 10, from: 12, to: 80 }, { topicId: 10, from: 12, to: 0 }]) h.value.jumpToReply(args);
  assert.deepEqual(h.jumps, []);
  h.value.jumpToReply({ topicId: 10, from: 12, to: 2 });
  assert.equal(h.value.returnTo, 12);
  h.value.goBack(); assert.equal(h.value.returnTo, null);
  assert.deepEqual(h.jumps, ["/t/topic/10/2", "/t/topic/10/12"]);
});

test("new messages never force a history reader to scroll; reaching the end clears the indicator", () => {
  const h = navigation(); h.flush(); assert.equal(h.value.away, true);
  h.value.topic.highest_post_number = 31;
  assert.equal(h.value.hasNew, true); assert.deepEqual(h.jumps, []);
  h.document.getElementById = () => ({ getBoundingClientRect: () => ({ bottom: 700 }) });
  h.value.scheduleCheck(); h.flush();
  assert.equal(h.value.away, false); assert.equal(h.value.hasNew, false);
});

const card = fs.readFileSync(new URL("../javascripts/discourse/api-initializers/profile-card.gjs", import.meta.url), "utf8");
const cardClass = card.slice(card.indexOf("class ProfileActions"), card.indexOf("  <template>")).replace(/^\s*@service[^\n]+/gm, "").replaceAll("@action ", "") + "}";
test("profile navigation snapshots its destination before the core dismiss clears the user", () => {
  const visited = [];
  const Class = new Function("Component", "DiscourseURL", `return ${cardClass}`)(class {}, { routeTo(path) { visited.push(path); } });
  const view = new Class();
  view.args = { outletArgs: { user: { path: "/u/example", id: 7 }, close() { this.user = null; } } };
  view.viewProfile({ preventDefault() {} });
  assert.deepEqual(visited, ["/u/example/summary"]);
});

const returnTopicPath = new Function(`${account.slice(account.indexOf("function returnTopicPath"), account.indexOf("function userLinks"))}; return returnTopicPath;`)();
test("returning from personal pages restores the last visible message, including numeric topic URLs", () => {
  const store = { get(key) { assert.equal(key, "wx-read-7-14"); return "23"; } };
  assert.equal(returnTopicPath("/t/topic/14/1?preview_theme_id=5", 7, store), "/t/topic/14/23?preview_theme_id=5");
  assert.equal(returnTopicPath("/t/14/1", 7, store), "/t/14/23");
  assert.equal(returnTopicPath(null, 7, store), "/latest");
  assert.equal(returnTopicPath("/t/topic/14", 7, { get() { return "NaN"; } }), "/t/topic/14");
});
