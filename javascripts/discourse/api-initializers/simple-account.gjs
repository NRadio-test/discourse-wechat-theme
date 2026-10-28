import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { on } from "@ember/modifier";
import { apiInitializer } from "discourse/lib/api";
import DiscourseURL from "discourse/lib/url";
import routeAction from "discourse/helpers/route-action";
import DButton from "discourse/ui-kit/d-button";
import PushNotificationSelect from "discourse/components/push-notification-select";
import UserNotificationSchedule from "discourse/components/user-notification-schedule";

let lastTopicPath = null;

function returnTopicPath(path, userId, store) {
  if (!path) return "/latest";
  const [pathname, query] = path.split("?");
  const parts = pathname.split("/");
  const idIndex = /^\d+$/.test(parts[2] || "") ? 2 : 3;
  const id = Number(parts[idIndex]);
  if (!Number.isSafeInteger(id) || id <= 0) return "/latest";
  const number = Number(store.get(`wx-read-${userId || "guest"}-${id}`));
  if (!Number.isSafeInteger(number) || number <= 0) return path;
  return `${parts.slice(0, idIndex + 1).join("/")}/${number}${query ? `?${query}` : ""}`;
}

function userLinks(user, own) {
  if (!user?.path) return [];
  const path = user.path;
  const links = user.profile_hidden || user.inactive ? [] : [
    { label: own ? "我" : "资料", href: `${path}/summary` },
    { label: own ? "我的话题" : "TA 的话题", href: `${path}/activity/topics` },
  ];
  if (own) links.push(
    { label: "消息", href: `${path}/notifications` },
    { label: "设置", href: `${path}/preferences/notifications` },
  );
  return links;
}

class AccountMenu extends Component {
  @service currentUser;
  get name() { return this.currentUser.name || this.currentUser.display_username || "社区成员"; }
  get avatar() { return this.currentUser.avatar_template?.replaceAll("{size}", "96"); }
  get links() { return userLinks(this.currentUser, true); }
  @action navigate(event) {
    if (event.button || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    event.preventDefault();
    this.args.closeUserMenu();
    DiscourseURL.routeTo(event.currentTarget.getAttribute("href"));
  }
  <template>
    <div class="wx-account-menu">
      <div class="wx-account-identity">{{#if this.avatar}}<img src={{this.avatar}} width="44" height="44" alt="" />{{/if}}<strong>{{this.name}}</strong></div>
      <nav aria-label="我的账户">{{#each this.links as |link|}}<a href={{link.href}} {{on "click" this.navigate}}>{{link.label}}<span aria-hidden="true">›</span></a>{{/each}}</nav>
      {{#if this.currentUser.staff}}<a href="/admin" {{on "click" this.navigate}}>管理后台</a>{{/if}}
      <DButton @translatedLabel="退出登录" @action={{routeAction "logout"}} class="wx-account-logout" />
    </div>
  </template>
}

class ProfileNavigation extends Component {
  @service currentUser;
  @service router;
  @service keyValueStore;
  get user() { return this.args.outletArgs.model; }
  get own() { return this.currentUser?.id === this.user?.id; }
  get backUrl() {
    if (this.settingsDetail) return `${this.user.path}/preferences/notifications`;
    if (this.isSettings || this.isActivity || this.isNotifications) return this.homeUrl;
    return returnTopicPath(lastTopicPath, this.currentUser?.id, this.keyValueStore);
  }
  get backLabel() { return this.settingsDetail ? "‹ 设置" : this.isSettings || this.isActivity || this.isNotifications ? (this.own ? "‹ 我" : "‹ 资料") : "‹ 返回聊天"; }
  get isActivity() { return this.router.currentURL?.includes("/activity/"); }
  get isSettings() { return this.router.currentURL?.includes("/preferences/"); }
  get settingsDetail() { return /\/preferences\/(users|security)(?:[?#]|$)/.test(this.router.currentURL || ""); }
  get isNotifications() { return !this.isSettings && this.router.currentURL?.includes("/notifications"); }
  get showHomeLink() { return this.own && (this.isActivity || this.isSettings || this.isNotifications); }
  get title() {
    const path = this.router.currentURL || "";
    if (path.includes("/preferences/users")) return "屏蔽管理";
    if (path.includes("/preferences/security")) return "登录与安全";
    if (this.isSettings) return "设置";
    if (path.includes("/notifications")) return "消息";
    if (this.isActivity) return this.own ? "我的话题" : "TA 的话题";
    return this.own ? "我" : "个人资料";
  }
  get homeUrl() { return `${this.user.path}/summary`; }
  get topicsUrl() { return `${this.user.path}/activity/topics`; }
  get repliesUrl() { return `${this.user.path}/activity/replies`; }
  get topicsActive() { return this.router.currentURL?.includes("/activity/topics") ? "page" : undefined; }
  get repliesActive() { return this.router.currentURL?.includes("/activity/replies") ? "page" : undefined; }
  get links() { return userLinks(this.user, this.own).map((link) => ({ ...link, current: this.router.currentURL?.split("?")[0] === link.href ? "page" : undefined })); }
  @action navigate(event) {
    if (event.button || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    event.preventDefault(); DiscourseURL.routeTo(event.currentTarget.getAttribute("href"));
  }
  <template>
    <div class={{if this.settingsDetail "wx-profile-navigation wx-settings-detail-page" "wx-profile-navigation"}}>
      <div class="wx-personal-heading"><a class="wx-return-topics" href={{this.backUrl}} {{on "click" this.navigate}}>{{this.backLabel}}</a><h1>{{this.title}}</h1>{{#if this.showHomeLink}}<a class="wx-personal-home" href={{this.homeUrl}} {{on "click" this.navigate}}>我</a>{{/if}}</div>
      {{#if this.isActivity}}<nav class="wx-activity-tabs" aria-label="我的话题分类"><a href={{this.topicsUrl}} aria-current={{this.topicsActive}} {{on "click" this.navigate}}>发起的</a><a href={{this.repliesUrl}} aria-current={{this.repliesActive}} {{on "click" this.navigate}}>参与的</a></nav>{{/if}}
      {{#if this.isSettings}}{{#unless this.settingsDetail}}<p class="wx-section-note">按你的习惯设置，随时可以调整。</p>{{/unless}}{{/if}}
    </div>
  </template>
}

class ProfileSummary extends Component {
  @service currentUser;
  @service siteSettings;
  get managedProfile() { return this.siteSettings.auth_overrides_name || this.siteSettings.auth_overrides_avatar || this.siteSettings.discourse_connect_overrides_avatar; }
  get user() { return this.args.outletArgs.user; }
  get visible() { return this.user && !this.user.profile_hidden && !this.user.inactive; }
  get own() { return this.currentUser?.id === this.user?.id; }
  get topics() { return `${this.user.path}/activity/topics`; }
  get replies() { return `${this.user.path}/activity/replies`; }
  get links() { return userLinks(this.user, this.own).filter((link) => !link.href.endsWith("/summary")); }
  @action navigate(event) {
    if (event.button || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    event.preventDefault(); DiscourseURL.routeTo(event.currentTarget.getAttribute("href"));
  }
  <template>
    {{#if this.visible}}<section class="wx-profile-summary">
      {{#each this.links as |link|}}<a href={{link.href}} {{on "click" this.navigate}}>{{link.label}}<span aria-hidden="true">›</span></a>{{/each}}
    </section>{{/if}}
  </template>
}

class SimpleSettings extends Component {
  @service currentUser;
  @tracked busy = false;
  @tracked message = "";
  @tracked error = false;
  get user() { return this.args.outletArgs.model; }
  get visible() { return this.user?.id === this.currentUser?.id; }
  get frequency() { return this.user.user_option.like_notification_frequency; }
  get frequencies() { return ["每次提醒", "每天首次", "每条消息首次", "不提醒"].map((label, value) => ({ label, value, selected: value === this.frequency })); }
  get linked() { return this.user.user_option.notify_on_linked_posts; }
  get usersUrl() { return `${this.user.path}/preferences/users`; }
  get securityUrl() { return `${this.user.path}/preferences/security`; }
  get accountUrl() { return this.currentUser?.zdwifi_managed ? `${this.user.path}/summary` : `${this.user.path}/preferences/account`; }
  @action navigate(event) {
    if (event.button || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    event.preventDefault(); DiscourseURL.routeTo(event.currentTarget.getAttribute("href"));
  }
  @action frequencyChanged(event) { this.persist("like_notification_frequency", Number(event.target.value)); }
  @action linkedChanged(event) { this.persist("notify_on_linked_posts", event.target.checked); }
  async persist(field, value) {
    if (this.busy || !this.visible) return;
    if (field === "like_notification_frequency" ? ![0, 1, 2, 3].includes(value) : field !== "notify_on_linked_posts" || typeof value !== "boolean") return;
    const user = this.user;
    const previous = user.user_option[field];
    this.busy = true; this.message = ""; this.error = false;
    user.set(`user_option.${field}`, value);
    try {
      await user.save([field]);
      if (!this.isDestroying && !this.isDestroyed) this.message = "已保存";
    } catch {
      user.set(`user_option.${field}`, previous);
      if (!this.isDestroying && !this.isDestroyed) { this.error = true; this.message = "保存未完成，已恢复原设置，请重试。"; }
    } finally { if (!this.isDestroying && !this.isDestroyed) this.busy = false; }
  }
  @action async saveSchedule() {
    if (this.busy || !this.visible) return;
    this.busy = true; this.error = false;
    try { await this.user.save(["user_notification_schedule"]); if (!this.isDestroying && !this.isDestroyed) this.message = "免打扰时间已保存"; }
    catch { if (!this.isDestroying && !this.isDestroyed) { this.error = true; this.message = "时间设置未保存，请重试。"; } }
    finally { if (!this.isDestroying && !this.isDestroyed) this.busy = false; }
  }
  <template>
    {{#if this.visible}}<section class="wx-settings" aria-label="社区设置">
      <h2>消息提醒</h2>
      <label class="wx-setting-row"><span>收到点赞</span><select aria-label="收到点赞时提醒" disabled={{this.busy}} {{on "change" this.frequencyChanged}}>{{#each this.frequencies as |item|}}<option value={{item.value}} selected={{item.selected}}>{{item.label}}</option>{{/each}}</select></label>
      <label class="wx-setting-row"><span>有人引用我的话题链接</span><input class="wx-switch" type="checkbox" role="switch" checked={{this.linked}} disabled={{this.busy}} {{on "change" this.linkedChanged}} /></label>
      {{#if this.message}}<p class={{if this.error "wx-settings-status is-error" "wx-settings-status"}} role="status">{{this.message}}</p>{{/if}}
      <details class="wx-settings-more"><summary>推送与免打扰</summary><div class="wx-setting-detail"><p>浏览器推送</p><PushNotificationSelect @model={{this.user}} /><p class="wx-section-note">仅对当前浏览器生效，微信内可能不支持。</p><UserNotificationSchedule @model={{this.user}} /><button type="button" class="wx-setting-save" disabled={{this.busy}} {{on "click" this.saveSchedule}}>保存免打扰时间</button></div></details>
      <nav class="wx-setting-links" aria-label="其他设置"><a href={{this.usersUrl}} {{on "click" this.navigate}}>屏蔽管理<span aria-hidden="true">›</span></a><a href={{this.securityUrl}} {{on "click" this.navigate}}>登录与安全<span aria-hidden="true">›</span></a><a href={{this.accountUrl}} {{on "click" this.navigate}}>账号资料<span aria-hidden="true">›</span></a></nav>
      <DButton @translatedLabel="退出登录" @action={{routeAction "logout"}} class="wx-account-logout" />
    </section>{{/if}}
  </template>
}

export default apiInitializer("1.0", (api) => {
  api.onPageChange((url) => { if (/^\/t\//.test(url || "")) lastTopicPath = url; });
  // Removing a destination is presentation only. Do not delete existing server
  // drafts or disable local recovery of unsent text and attachments.
  api.modifyClass("route:userActivity.drafts", (Superclass) => class extends Superclass {
    beforeModel() { return this.router.replaceWith("discovery.latest"); }
  });
  api.modifyClass("route:userActivity.bookmarks", (Superclass) => class extends Superclass {
    beforeModel() { return this.router.replaceWith("discovery.latest"); }
  });
  api.modifyClass("route:userActivity.index", (Superclass) => class extends Superclass {
    beforeModel() { return this.router.replaceWith("userActivity.topics", this.modelFor("user")); }
  });
  api.modifyClass("route:user.index", (Superclass) => class extends Superclass {
    beforeModel() { return this.router.replaceWith("user.summary", this.modelFor("user")); }
  });
  // Old links can also arrive from a login provider or browser bookmarks.
  // The restricted preferences parent still authorizes the account first.
  for (const route of ["interface", "tracking", "navigation-menu", "calendar-subscriptions"]) {
    api.modifyClass(`route:preferences.${route}`, (Superclass) => class extends Superclass {
      beforeModel() { return this.router.replaceWith("preferences.notifications", this.modelFor("user")); }
    });
  }
  const nativePanels = new WeakMap();
  api.modifyClass("component:user-menu/menu", (Superclass) => class extends Superclass {
    get nativeAccountMenu() {
      return api.container.lookup("service:router").currentURL?.startsWith("/admin");
    }
    get topTabs() {
      const tabs = super.topTabs;
      // All notifications still includes replies, likes and moderation alerts.
      const visible = this.nativeAccountMenu ? tabs : tabs.filter((tab) =>
        !["bookmarks", "replies", "likes", "other-notifications"].includes(tab.id));
      // The core caches tab instances. Restore their positions on admin routes.
      return visible.map((tab, position) => { tab.position = position; return tab; });
    }
    get bottomTabs() {
      return super.bottomTabs.map((tab, index) => {
        if (!nativePanels.has(tab)) nativePanels.set(tab, tab.panelComponent);
        tab.panelComponent = !this.nativeAccountMenu && tab.id === "profile" ? AccountMenu : nativePanels.get(tab);
        tab.position = this.topTabs.length + index;
        return tab;
      });
    }
  });
  api.renderInOutlet("above-user-profile", ProfileNavigation);
  api.renderInOutlet("above-user-summary-stats", ProfileSummary);
  api.renderInOutlet("user-preferences-notifications", SimpleSettings);
});
