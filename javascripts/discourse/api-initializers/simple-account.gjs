import Component from "@glimmer/component";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { on } from "@ember/modifier";
import { apiInitializer } from "discourse/lib/api";
import DiscourseURL from "discourse/lib/url";
import routeAction from "discourse/helpers/route-action";
import DButton from "discourse/ui-kit/d-button";

function userLinks(user, own) {
  if (!user?.path) return [];
  const path = user.path;
  const links = user.profile_hidden || user.inactive ? [] : [
    { label: "个人资料", href: `${path}/summary` },
    { label: "发起的话题", href: `${path}/activity/topics` },
    { label: "参与的讨论", href: `${path}/activity/replies` },
  ];
  if (own) links.push(
    { label: "消息通知", href: `${path}/notifications` },
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
  get user() { return this.args.outletArgs.model; }
  get own() { return this.currentUser?.id === this.user?.id; }
  get links() { return userLinks(this.user, this.own).map((link) => ({ ...link, current: this.router.currentURL?.split("?")[0] === link.href ? "page" : undefined })); }
  @action navigate(event) {
    if (event.button || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    event.preventDefault(); DiscourseURL.routeTo(event.currentTarget.getAttribute("href"));
  }
  <template>
    <div class="wx-profile-navigation">
      <a class="wx-return-topics" href="/latest" {{on "click" this.navigate}}>‹ 返回话题</a>
      <nav aria-label="个人页面">{{#each this.links as |link|}}<a href={{link.href}} aria-current={{link.current}} {{on "click" this.navigate}}>{{link.label}}</a>{{/each}}</nav>
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
  @action navigate(event) {
    if (event.button || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    event.preventDefault(); DiscourseURL.routeTo(event.currentTarget.getAttribute("href"));
  }
  <template>
    {{#if this.visible}}<section class="wx-profile-summary">
      {{#if this.own}}{{#if this.managedProfile}}<p>昵称和头像与登录账号同步。</p>{{/if}}{{/if}}
      <a href={{this.topics}} {{on "click" this.navigate}}>发起的话题<span aria-hidden="true">›</span></a>
      <a href={{this.replies}} {{on "click" this.navigate}}>参与的讨论<span aria-hidden="true">›</span></a>
    </section>{{/if}}
  </template>
}

export default apiInitializer("1.0", (api) => {
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
});
