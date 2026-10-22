import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { registerDestructor } from "@ember/destroyable";
import { on } from "@ember/modifier";
import { fn } from "@ember/helper";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import willDestroy from "@ember/render-modifiers/modifiers/will-destroy";
import DockedComposer from "discourse/components/docked-composer";
import DButton from "discourse/ui-kit/d-button";
import { extractError } from "discourse/lib/ajax-error";
import { ajax } from "discourse/lib/ajax";
import { getUploadMarkdown } from "discourse/lib/uploads";
import { apiInitializer } from "discourse/lib/api";
import DiscourseURL from "discourse/lib/url";
import { clipboardCopy } from "discourse/lib/utilities";

const themeSettings = typeof settings === "undefined" ? {} : settings;
function featuredPath(value) {
  try {
    const path = decodeURI(String(value || "/tag/精华").trim());
    return /^\/tag\/[^/?#]+(?:\/\d+)?$/.test(path) && !/[\\\x00-\x20]/.test(path) ? path : "/tag/精华";
  } catch { return "/tag/精华"; }
}
const featuredUrl = featuredPath(themeSettings.featured_tag_path);
const featuredKey = featuredUrl.split("/").at(-1);
const TABS = [
  { key: "top", label: "十大", url: "/top?period=daily", filter: "top", params: { period: "daily" } },
  { key: "all", label: "全部", url: "/latest", filter: "latest", params: {} },
  { key: "featured", label: "精华", url: featuredUrl, filter: `tag/${encodeURIComponent(featuredKey)}/l/latest`, params: {} },
];

function pageKind(url) {
  const path = (url || "/").split("?")[0];
  if (/^\/t\//.test(path)) return "topic";
  if (path === "/" || /^\/top(?:\/|$)/.test(path)) return "top";
  if (path === "/latest") return "all";
  let decoded = path;
  try { decoded = decodeURI(path); } catch { /* Keep malformed URLs outside the shell. */ }
  if (decoded === featuredUrl || (/^\/tag\//.test(decoded) && decoded.split("/").at(-1) === featuredKey)) return "featured";
  return "other";
}

export default apiInitializer("1.0", (api) => {
  api.modifyClass("route:user", (Superclass) => class extends Superclass {
    titleToken() {
      const name = this.modelFor("user")?.name?.trim();
      return this.siteSettings.enable_names && !this.siteSettings.prioritize_username_in_ux && name
        ? name : super.titleToken(...arguments);
    }
  });

  // A request outlives its topic outlet. Keep its lock when A → B → A
  // creates a new InlineReply instance before A's request has finished.
  const pendingReplies = new Map();
  let activeMessageActions = null;
  let activeTextSelection = null;
  let messageActionSequence = 0;

  class Conversations extends Component {
    @service siteSettings;
    @service router;
    @service store;
    @service currentUser;
    @service appEvents;
    @tracked path = this.router.currentURL || window.location.pathname;
    @tracked tab = "top";
    @tracked model;
    @tracked loading = false;
    @tracked error = false;
    @tracked loadingMore = false;
    requestNumber = 0;

    constructor() {
      super(...arguments);
      this.routeChanged();
      this.router.on("routeDidChange", this.routeChanged);
      this.appEvents.on("wx:message-sent", this, this.refreshAfterMessage);
      registerDestructor(this, () => {
        this.requestNumber++;
        this.router.off("routeDidChange", this.routeChanged);
        this.appEvents.off("wx:message-sent", this, this.refreshAfterMessage);
      });
    }

    get kind() { return pageKind(this.path); }
    get communityName() { return themeSettings.community_name?.trim() || this.siteSettings.title; }
    get footerText() { return themeSettings.footer_text?.trim() || this.communityName; }
    get welcomeTitle() { return themeSettings.welcome_title || "一起聊聊感兴趣的话题"; }
    get welcomeDescription() { return themeSettings.welcome_description || "选一个感兴趣的话题，加入讨论"; }
    get visible() { return this.kind !== "other"; }
    get isTopic() { return this.kind === "topic"; }
    get backUrl() { return TABS.find((t) => t.key === this.tab).url; }
    get selectedId() {
      const parts = this.path.split("?")[0].split("/");
      return Number(/^\d+$/.test(parts[2] || "") ? parts[2] : parts[3]);
    }
    get tabs() { return TABS.map((t) => ({ ...t, selected: t.key === this.tab, current: t.key === this.tab ? "page" : undefined })); }
    get canLoadMore() { return this.tab !== "top" && this.model?.canLoadMore; }
    get description() { return this.tab === "top" ? "今天，大家都在聊什么" : this.tab === "all" ? "所有话题，都在这里" : "值得反复看的好内容"; }
    get emptyText() { return this.tab === "top" ? "今天还没有热门讨论" : this.tab === "featured" ? "精选话题会出现在这里" : "还没有话题，来聊第一句吧"; }
    get rows() {
      let topics = this.model?.topics || [];
      if (this.tab === "top") topics = topics.slice(0, 10);
      return topics.map((topic) => {
        const user = topic.posters?.[0]?.user;
        const avatar = user?.avatar_template?.replaceAll("{size}", "96");
        const replies = Math.max(0, topic.posts_count - 1);
        const excerpt = topic.excerpt ? new DOMParser().parseFromString(topic.excerpt, "text/html").body.textContent.trim() : "";
        const date = new Date(topic.bumped_at || topic.last_posted_at || topic.created_at);
        const now = new Date();
        const time = date.toDateString() === now.toDateString()
          ? date.toLocaleTimeString("zh-CN", { hour: "2-digit", minute: "2-digit", hour12: false })
          : date.toLocaleDateString("zh-CN", { month: "numeric", day: "numeric" });
        return {
          id: topic.id, title: topic.title, avatar, time,
          dateTime: date.toISOString(), replies,
          preview: excerpt.slice(0, 90) || `${replies} 条回复${topic.like_count ? ` · ${topic.like_count} 个赞` : ""}`,
          href: `/t/${topic.slug || "topic"}/${topic.id}/${topic.highest_post_number || 1}`,
          selected: topic.id === this.selectedId,
          current: topic.id === this.selectedId ? "page" : undefined,
        };
      });
    }

    @action routeChanged() {
      this.path = this.router.currentURL || window.location.pathname;
      const kind = this.kind;
      document.body.classList.toggle("wx-forum", kind !== "other");
      document.body.classList.toggle("wx-topic", kind === "topic");
      document.body.classList.toggle("wx-discovery", ["top", "all", "featured"].includes(kind));
      if (kind !== "other" && kind !== "topic" && kind !== this.tab) {
        this.tab = kind;
        this.model = null;
        this.load();
      } else if (kind !== "other" && !this.model && !this.loading) {
        this.load();
      }
    }

    @action async load() {
      const request = ++this.requestNumber;
      this.loading = true;
      this.loadingMore = false;
      this.error = false;
      const tab = TABS.find((t) => t.key === this.tab);
      try {
        const model = await this.store.findFiltered("topicList", { filter: tab.filter, params: tab.params });
        if (request === this.requestNumber) this.model = model;
      } catch {
        if (request === this.requestNumber) this.error = true;
      } finally {
        if (request === this.requestNumber) this.loading = false;
      }
    }

    @action async more() {
      if (this.loadingMore || !this.canLoadMore) return;
      const model = this.model;
      const request = this.requestNumber;
      this.loadingMore = true;
      try { await model.loadMore(); } catch {
        model.set("loadingMore", false);
        if (request === this.requestNumber && model === this.model) this.error = true;
      } finally {
        if (request === this.requestNumber && model === this.model) this.loadingMore = false;
      }
    }

    @action navigate(event) {
      if (event.button || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
      event.preventDefault();
      DiscourseURL.routeTo(event.currentTarget.getAttribute("href"));
    }

    @action chooseTab(tab, event) {
      if (event.button || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
      event.preventDefault();
      this.tab = tab.key;
      this.model = null;
      this.load();
      if (!this.isTopic) DiscourseURL.routeTo(tab.url);
    }

    @action newTopic() { this.appEvents.trigger("wx:new-topic"); }
    @action refreshAfterMessage() { if (this.visible) this.load(); }

    <template>
      {{#if this.visible}}
        <aside class="wx-conversations" aria-label="话题会话列表">
          <div class="wx-list-heading"><span>话题</span><button type="button" class="wx-icon-button wx-refresh" aria-label="刷新话题" title="刷新话题" {{on "click" this.load}}>↻</button></div>
          <nav class="wx-tabs" aria-label="论坛内容">
            {{#each this.tabs as |tab|}}
              <a href={{tab.url}} class={{if tab.selected "wx-tab is-active" "wx-tab"}} aria-current={{tab.current}} {{on "click" (fn this.chooseTab tab)}}>{{tab.label}}</a>
            {{/each}}
          </nav>
          <div class="wx-list-scroll">
            <p class="wx-list-description">{{this.description}}</p>
            {{#if this.loading}}<p class="wx-list-state" role="status">正在加载话题…</p>{{/if}}
            {{#if this.error}}<div class="wx-list-state wx-list-error" role="alert">话题加载失败<button type="button" {{on "click" this.load}}>重试</button></div>{{/if}}
            {{#unless this.loading}}
              {{#each this.rows as |row|}}
                <a href={{row.href}} class={{if row.selected "wx-conversation is-selected" "wx-conversation"}} aria-current={{row.current}} {{on "click" this.navigate}}>
                  <span class="wx-conversation-avatar">{{#if row.avatar}}<img src={{row.avatar}} alt="" loading="lazy" width="48" height="48" />{{else}}<span aria-hidden="true">聊</span>{{/if}}</span>
                  <span class="wx-conversation-content"><span class="wx-conversation-line"><span class="wx-conversation-title">{{row.title}}</span><time datetime={{row.dateTime}}>{{row.time}}</time></span><span class="wx-conversation-preview">{{row.preview}}</span></span>
                </a>
              {{else}}
                {{#unless this.error}}<div class="wx-list-empty"><svg class="wx-empty-mark" width="44" height="40" viewBox="0 0 44 40" aria-hidden="true"><path d="M22 4C11 4 3 11 3 20c0 5 3 9 7 12l-2 5 8-4c2 1 4 1 6 1 11 0 19-6 19-14S33 4 22 4Z" fill="none" stroke="currentColor" stroke-width="1.5"/><circle cx="15" cy="19" r="1.8" fill="currentColor"/><circle cx="29" cy="19" r="1.8" fill="currentColor"/></svg><p>{{this.emptyText}}</p><button type="button" {{on "click" this.newTopic}}>发起话题</button></div>{{/unless}}
              {{/each}}
              {{#if this.canLoadMore}}<button type="button" class="wx-load-more" disabled={{this.loadingMore}} {{on "click" this.more}}>{{if this.loadingMore "正在加载…" "查看更多话题"}}</button>{{/if}}
            {{/unless}}
          </div>
          <div class="wx-list-footer"><span>{{this.footerText}}</span><button type="button" class="wx-new-topic" aria-label="发起新话题" title="发起新话题" {{on "click" this.newTopic}}>＋</button></div>
        </aside>
        {{#unless this.isTopic}}<section class="wx-welcome" aria-label="选择一个话题"><svg width="74" height="64" viewBox="0 0 74 64" aria-hidden="true"><path d="M37 5C19 5 5 16 5 30c0 8 4 14 11 19l-3 10 13-6c4 1 7 2 11 2 18 0 32-11 32-25S55 5 37 5Z" fill="none" stroke="currentColor" stroke-width="2"/><circle cx="24" cy="29" r="3" fill="currentColor"/><circle cx="49" cy="29" r="3" fill="currentColor"/></svg><h1>{{this.welcomeTitle}}</h1><p>{{this.welcomeDescription}}</p><button type="button" {{on "click" this.newTopic}}>发起新话题</button></section>{{/unless}}
        <a class="wx-mobile-back" href={{this.backUrl}} aria-label="返回话题列表" {{on "click" this.navigate}}>‹</a>
      {{/if}}
    </template>
  }

  // This wrapper keeps the real PostMenu alive, including its permission checks,
  // native dialogs and reply action. No buttons or permission logic are copied.
  class MessageActions extends Component {
    instanceId = ++messageActionSequence;
    @service router;
    @tracked isOpen = false;
    @tracked isSelecting = false;
    @tracked ready = false;
    @tracked copyState = "";
    element = null;
    postElement = null;
    bubble = null;
    menu = null;
    press = null;
    pressTimer = null;
    positionFrame = null;
    actionFrame = null;
    suppressClickUntil = 0;
    lastPointerType = "mouse";
    touchGestureMoved = false;
    menuRevision = 0;
    interactiveSelector = "button, input, textarea, select, video, audio, iframe, [contenteditable]";
    nestedPopupSelector = ".fk-d-menu, .fk-d-menu-modal, .d-modal, .modal-inner-container, .emoji-picker";

    constructor() {
      super(...arguments);
      registerDestructor(this, () => this.teardown());
    }

    get enabled() { return !this.args.outletArgs.state?.nestedReplyView && /^\/t\//.test(this.router.currentURL || ""); }
    get post() { return this.args.outletArgs.post; }
    get menuId() { return `wx-message-menu-${this.post.id}-${this.instanceId}`; }
    get triggerLabel() { return `第 ${this.post.post_number} 条消息操作`; }
    get isClosed() { return this.ready && !this.isOpen; }
    get triggerHidden() { return !this.ready; }
    get canCopy() { return !!(this.bubble?.innerText || this.bubble?.textContent || "").trim(); }
    get copying() { return this.copyState === "copying"; }
    get copied() { return this.copyState === "copied"; }
    get copyLabel() { return this.copyState === "copied" ? "已复制" : this.copying ? "复制中…" : "复制"; }
    get copyError() { return this.copyState === "failed"; }

    @action setup(element) {
      this.teardown();
      this.element = element;
      this.postElement = element.closest(".topic-post");
      this.bubble = this.postElement?.querySelector(".post__contents > .cooked");
      this.menu = element.querySelector(".wx-message-actions-popover");
      if (!this.postElement || !this.bubble || !this.menu) return;
      // Core re-renders the post's complete class attribute. Theme-owned data
      // attributes survive that update and never compete with its class list.
      this.postElement.dataset.wxMessageActions = "true";
      // Establish touch behavior before the browser starts its native long-press
      // timer. A later mouse pointer restores normal desktop text selection.
      if (window.matchMedia?.("(any-pointer: coarse)").matches) this.setPointerMode("touch");
      this.postElement.addEventListener("pointerdown", this.pointerDown, { passive: true });
      this.postElement.addEventListener("contextmenu", this.contextMenu);
      this.postElement.addEventListener("keydown", this.postKeyDown);
      this.postElement.addEventListener("click", this.suppressHeldClick, true);
      this.postElement.addEventListener("selectstart", this.selectionStart);
      this.postElement.addEventListener("touchend", this.heldTouchEnd, { passive: false });
      // Core DButton actions may stop bubbling; observe without cancelling
      // during capture, then close after the native action has dispatched.
      this.menu.addEventListener("click", this.menuClick, true);
      this.ready = true;
    }

    @action teardown() {
      this.cancelPress();
      this.closeMenu();
      this.endTextSelection();
      if (this.positionFrame !== null) window.cancelAnimationFrame(this.positionFrame);
      if (this.actionFrame !== null) window.cancelAnimationFrame(this.actionFrame);
      this.positionFrame = this.actionFrame = null;
      if (this.postElement) {
        delete this.postElement.dataset.wxMessageActions;
        delete this.postElement.dataset.wxPointerMode;
      }
      this.postElement?.removeEventListener("pointerdown", this.pointerDown);
      this.postElement?.removeEventListener("contextmenu", this.contextMenu);
      this.postElement?.removeEventListener("keydown", this.postKeyDown);
      this.postElement?.removeEventListener("click", this.suppressHeldClick, true);
      this.postElement?.removeEventListener("selectstart", this.selectionStart);
      this.postElement?.removeEventListener("touchend", this.heldTouchEnd);
      this.menu?.removeEventListener("click", this.menuClick, true);
      this.element = this.postElement = this.bubble = this.menu = null;
      if (!this.isDestroying && !this.isDestroyed) this.ready = false;
    }

    eligibleTarget(target) {
      // Links and pictures are part of the message: taps keep their native
      // action, while a completed touch hold opens this message's controls.
      return !!(target?.closest && this.bubble?.contains(target) && !target.closest(this.interactiveSelector));
    }

    setPointerMode(type) {
      this.lastPointerType = type || "mouse";
      const touch = ["touch", "pen"].includes(this.lastPointerType);
      if (this.postElement) this.postElement.dataset.wxPointerMode = touch ? "touch" : "mouse";
    }

    closeQuoteToolbar() {
      // The core owns this floating menu. Close its exact identifier rather
      // than hiding unrelated menus.
      api.container.lookup("service:menu").close("post-text-selection-toolbar");
      api.container.lookup("controller:topic").quoteState?.clear();
    }

    clearBubbleSelection() {
      const selection = window.getSelection?.();
      // A collapsed range or whitespace can still leave native selection
      // handles. Only clear ranges belonging to this message or its menu.
      if (selection && [selection.anchorNode, selection.focusNode].some((node) =>
        node && this.postElement?.contains(node) &&
        !(node.nodeType === 3 ? node.parentElement : node).closest?.("input, textarea, [contenteditable]"))) {
        selection.removeAllRanges();
      }
    }

    @action selectionStart(event) {
      if (this.isSelecting || !["touch", "pen"].includes(this.lastPointerType)) return;
      const target = event.target?.nodeType === 3 ? event.target.parentElement : event.target;
      if (target?.closest?.("input, textarea, [contenteditable]")) return;
      if (this.eligibleTarget(target) || this.menu?.contains(target)) event.preventDefault();
    }

    @action selectionChanged() {
      // WebViews can create a range after the hold timer/contextmenu callback.
      // Listen only during our gesture/menu, never during explicit selection.
      if (!this.isSelecting && (this.press || this.isOpen) &&
          ["touch", "pen"].includes(this.lastPointerType)) this.clearBubbleSelection();
    }

    @action heldTouchEnd(event) {
      // Cancel only the release of a completed hold. Short taps, scrolling and
      // explicit text selection keep their native touch behavior.
      if (this.isOpen && !this.isSelecting && Date.now() < this.suppressClickUntil &&
          this.eligibleTarget(event.target)) {
        event.preventDefault();
        this.clearBubbleSelection();
      }
    }

    hasSelectedText() {
      const selection = window.getSelection?.();
      return !!(selection && !selection.isCollapsed && selection.toString().trim() &&
        (this.bubble?.contains(selection.anchorNode) || this.bubble?.contains(selection.focusNode)));
    }

    @action pointerDown(event) {
      this.cancelPress();
      this.suppressClickUntil = 0;
      this.setPointerMode(event.pointerType);
      this.touchGestureMoved = false;
      if (event.isPrimary === false || event.button !== 0 ||
          !["touch", "pen"].includes(this.lastPointerType) ||
          !this.eligibleTarget(event.target) || this.isSelecting) return;

      this.clearBubbleSelection();
      this.closeQuoteToolbar();

      this.press = { pointerId: event.pointerId, x: event.clientX, y: event.clientY };
      document.addEventListener("selectionchange", this.selectionChanged);
      document.addEventListener("pointermove", this.pointerMove, { capture: true, passive: true });
      document.addEventListener("pointerup", this.pointerEnd, true);
      document.addEventListener("pointercancel", this.pointerEnd, true);
      document.addEventListener("scroll", this.viewportChanged, { capture: true, passive: true });
      this.pressTimer = window.setTimeout(() => {
        const press = this.press;
        if (!press) return;
        this.suppressClickUntil = Date.now() + 900;
        this.openMenu({ x: press.x, y: press.y, focus: false });
      }, 480);
    }

    @action pointerMove(event) {
      if (!this.press || event.pointerId !== this.press.pointerId) return;
      if (Math.hypot(event.clientX - this.press.x, event.clientY - this.press.y) > 8) {
        this.touchGestureMoved = true;
        this.cancelPress();
      }
    }

    @action pointerEnd(event) {
      if (event.type === "pointercancel") this.touchGestureMoved = true;
      if (!this.press || event.pointerId === this.press.pointerId) this.cancelPress();
    }

    cancelPress() {
      if (this.pressTimer !== null) window.clearTimeout(this.pressTimer);
      this.pressTimer = null;
      this.press = null;
      document.removeEventListener("pointermove", this.pointerMove, true);
      document.removeEventListener("pointerup", this.pointerEnd, true);
      document.removeEventListener("pointercancel", this.pointerEnd, true);
      if (!this.isOpen) {
        document.removeEventListener("scroll", this.viewportChanged, true);
        document.removeEventListener("selectionchange", this.selectionChanged);
      }
    }

    @action contextMenu(event) {
      if (this.menu?.contains(event.target) && ["touch", "pen"].includes(this.lastPointerType) &&
          !event.target.closest?.("input, textarea, [contenteditable]")) {
        event.preventDefault();
        this.clearBubbleSelection();
        return;
      }
      if (!this.eligibleTarget(event.target)) return;
      const touch = ["touch", "pen"].includes(event.pointerType || this.lastPointerType);
      // Explicit selection gets only the operating system's native menu.
      // Desktop selection and link context menus remain familiar as well.
      if (this.isSelecting || (!touch && (this.hasSelectedText() || event.target.closest("a")))) {
        this.cancelPress();
        return;
      }
      event.preventDefault();
      if (touch && this.touchGestureMoved) return;
      if (this.isOpen) return;
      this.suppressClickUntil = Date.now() + 900;
      this.openMenu({ x: event.clientX, y: event.clientY, focus: !touch });
    }

    @action postKeyDown(event) {
      if (event.key !== "ContextMenu" && !(event.shiftKey && event.key === "F10")) return;
      const trigger = event.target.closest?.(".wx-message-actions-trigger");
      if (!trigger && !this.eligibleTarget(event.target)) return;
      if (!trigger && (this.isSelecting || this.hasSelectedText() || event.target.closest("a"))) return;
      event.preventDefault();
      this.openMenu({ focus: true });
    }

    @action suppressHeldClick(event) {
      if (Date.now() > this.suppressClickUntil || !this.eligibleTarget(event.target)) return;
      this.suppressClickUntil = 0;
      event.preventDefault();
      event.stopPropagation();
    }

    @action toggleMenu() {
      if (this.isOpen) this.closeMenu(true);
      else this.openMenu({ focus: true });
    }

    openMenu({ x, y, focus = false } = {}) {
      if (!this.menu || !this.bubble?.isConnected || this.isDestroying || this.isDestroyed) return;
      this.cancelPress();
      activeTextSelection?.endTextSelection();
      if (["touch", "pen"].includes(this.lastPointerType)) {
        this.clearBubbleSelection();
        this.closeQuoteToolbar();
      }
      activeMessageActions?.closeMenu();
      activeMessageActions = this;
      this.isOpen = true;
      this.menuRevision++;
      this.copyState = "";
      this.postElement.dataset.wxMenuOpen = "true";
      document.addEventListener("pointerdown", this.outsidePointer, true);
      document.addEventListener("keydown", this.documentKeyDown, true);
      document.addEventListener("focusin", this.focusChanged, true);
      document.addEventListener("selectionchange", this.selectionChanged);
      document.addEventListener("scroll", this.viewportChanged, { capture: true, passive: true });
      window.addEventListener("resize", this.viewportChanged, { passive: true });
      window.visualViewport?.addEventListener("resize", this.viewportChanged, { passive: true });
      this.positionFrame = window.requestAnimationFrame(() => {
        this.positionFrame = null;
        if (!this.isOpen || !this.menu?.isConnected) return;
        this.positionMenu(x, y);
        if (focus) (this.focusableButtons()[0] || this.menu).focus({ preventScroll: true });
      });
    }

    positionMenu(x, y) {
      const rect = this.bubble.getBoundingClientRect();
      const viewport = window.visualViewport;
      const leftEdge = viewport?.offsetLeft || 0;
      const viewportTop = viewport?.offsetTop || 0;
      const headerBottom = document.querySelector(".d-header")?.getBoundingClientRect().bottom;
      const topEdge = Math.max(viewportTop, Number.isFinite(headerBottom) ? headerBottom : 0);
      const width = viewport?.width || window.innerWidth;
      const height = viewport?.height || window.innerHeight;
      const dockTop = document.querySelector(".wx-reply-dock")?.getBoundingClientRect().top;
      const bottomEdge = Math.min(viewportTop + height, Number.isFinite(dockTop) ? dockTop : Infinity) - 8;
      this.menu.style.setProperty("--wx-message-menu-max-height", `${Math.max(80, bottomEdge - topEdge - 16)}px`);
      const menuRect = this.menu.getBoundingClientRect();
      const anchorX = Number.isFinite(x) && x > 0 ? x : rect.left + rect.width / 2;
      const anchorY = Number.isFinite(y) && y > 0 ? y : Math.min(rect.bottom, topEdge + height / 2);
      const left = Math.max(leftEdge + 8, Math.min(anchorX - menuRect.width / 2, leftEdge + width - menuRect.width - 8));
      const preferredTop = anchorY - menuRect.height - 14;
      const top = Math.max(topEdge + 8, Math.min(preferredTop >= topEdge + 8 ? preferredTop : anchorY + 14, bottomEdge - menuRect.height));
      this.menu.style.setProperty("--wx-message-menu-left", `${Math.round(left)}px`);
      this.menu.style.setProperty("--wx-message-menu-top", `${Math.round(top)}px`);
      this.menu.dataset.positioned = "true";
    }

    closeMenu(restoreFocus = false) {
      const wasOpen = this.isOpen;
      this.menuRevision++;
      if (wasOpen && !this.isSelecting && ["touch", "pen"].includes(this.lastPointerType)) this.clearBubbleSelection();
      if (!this.isDestroying && !this.isDestroyed) this.isOpen = false;
      if (activeMessageActions === this) activeMessageActions = null;
      if (this.positionFrame !== null) window.cancelAnimationFrame(this.positionFrame);
      this.positionFrame = null;
      if (this.postElement) delete this.postElement.dataset.wxMenuOpen;
      if (this.menu) delete this.menu.dataset.positioned;
      document.removeEventListener("pointerdown", this.outsidePointer, true);
      document.removeEventListener("keydown", this.documentKeyDown, true);
      document.removeEventListener("focusin", this.focusChanged, true);
      document.removeEventListener("selectionchange", this.selectionChanged);
      document.removeEventListener("scroll", this.viewportChanged, true);
      window.removeEventListener("resize", this.viewportChanged);
      window.visualViewport?.removeEventListener("resize", this.viewportChanged);
      if (wasOpen && restoreFocus) this.element?.querySelector(".wx-message-actions-trigger")?.focus({ preventScroll: true });
    }

    isNestedPopup(target) { return !!target?.closest?.(this.nestedPopupSelector); }

    @action outsidePointer(event) {
      if (!this.element?.contains(event.target) && !this.isNestedPopup(event.target)) this.closeMenu();
    }

    @action focusChanged(event) {
      if (!this.element?.contains(event.target) && !this.isNestedPopup(event.target)) this.closeMenu();
    }

    @action viewportChanged(event) {
      if (event?.target && (this.menu?.contains(event.target) || this.isNestedPopup(event.target))) return;
      this.touchGestureMoved = true;
      this.cancelPress();
      this.closeMenu();
    }

    @action selectText() {
      if (!this.canCopy || !this.bubble?.isConnected) return;
      this.closeMenu();
      activeTextSelection?.endTextSelection();
      activeTextSelection = this;
      this.isSelecting = true;
      this.suppressClickUntil = 0;
      this.postElement.dataset.wxSelecting = "true";
      this.closeQuoteToolbar();
      document.addEventListener("pointerdown", this.selectionOutside, true);
      document.addEventListener("keydown", this.selectionKeyDown, true);
      // This user-initiated range gives native selection handles on supported
      // WebViews. Other browsers can long-press the now-selectable text.
      const selection = window.getSelection?.();
      const range = document.createRange();
      range.selectNodeContents(this.bubble);
      selection?.removeAllRanges();
      selection?.addRange(range);
    }

    @action endTextSelection() {
      if (activeTextSelection === this) activeTextSelection = null;
      if (this.isSelecting) this.clearBubbleSelection();
      if (!this.isDestroying && !this.isDestroyed) this.isSelecting = false;
      if (this.postElement) delete this.postElement.dataset.wxSelecting;
      document.removeEventListener("pointerdown", this.selectionOutside, true);
      document.removeEventListener("keydown", this.selectionKeyDown, true);
    }

    @action selectionOutside(event) {
      if (!this.bubble?.contains(event.target) && !this.element?.contains(event.target) && !this.isNestedPopup(event.target)) this.endTextSelection();
    }

    @action selectionKeyDown(event) {
      if (event.key !== "Escape") return;
      event.preventDefault();
      this.endTextSelection();
      this.element?.querySelector(".wx-message-actions-trigger")?.focus({ preventScroll: true });
    }

    @action documentKeyDown(event) {
      if (event.key !== "Escape" || this.isNestedPopup(event.target)) return;
      event.preventDefault();
      event.stopPropagation();
      this.closeMenu(true);
    }

    focusableButtons() {
      return [...(this.menu?.querySelectorAll("button:not(:disabled), a[href], [tabindex='0']") || [])]
        .filter((element) => element.getClientRects().length > 0);
    }

    @action menuKeyDown(event) {
      if (!["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Home", "End"].includes(event.key)) return;
      const buttons = this.focusableButtons();
      if (!buttons.length) return;
      const index = buttons.indexOf(document.activeElement);
      const next = event.key === "Home" ? 0 : event.key === "End" ? buttons.length - 1 :
        (index + (["ArrowLeft", "ArrowUp"].includes(event.key) ? -1 : 1) + buttons.length) % buttons.length;
      event.preventDefault();
      buttons[next].focus({ preventScroll: true });
    }

    @action menuClick(event) {
      // Bookmark/admin/liked-user popovers retain their native anchor until the
      // nested interaction ends. Immediate actions can safely close this shell.
      const immediate = event.target.closest?.(".post-action-menu__reply, .post-action-menu__like, .post-action-menu__share, .post-action-menu__copy-link, .post-action-menu__edit, .post-action-menu__delete, .post-action-menu__recover, .post-action-menu__flag");
      if (!immediate || immediate.disabled) return;
      this.actionFrame = window.requestAnimationFrame(() => {
        this.actionFrame = null;
        this.closeMenu();
      });
    }

    @action async copyBody() {
      if (this.copying || !this.isOpen) return;
      const text = (this.bubble?.innerText || this.bubble?.textContent || "").trim();
      if (!text) return;
      this.copyState = "copying";
      const revision = this.menuRevision;
      try {
        await clipboardCopy(text);
        if (!this.isDestroying && !this.isDestroyed && revision === this.menuRevision) {
          this.copyState = "copied";
          this.clearBubbleSelection();
          this.closeMenu();
        }
      } catch {
        if (!this.isDestroying && !this.isDestroyed && revision === this.menuRevision) {
          this.clearBubbleSelection();
          this.copyState = "failed";
        }
      }
    }

    <template>
      {{#if this.enabled}}
        <div class={{if this.ready "wx-message-actions is-enhanced" "wx-message-actions"}} {{didInsert this.setup}} {{willDestroy this.teardown}}>
          <button type="button" class="wx-message-actions-trigger" hidden={{this.triggerHidden}} aria-label={{this.triggerLabel}} aria-haspopup="dialog" aria-controls={{this.menuId}} aria-expanded={{this.isOpen}} {{on "click" this.toggleMenu}}>•••</button>
          <div id={{this.menuId}} class="wx-message-actions-popover" role={{if this.ready "dialog"}} aria-label="消息操作" tabindex="-1" hidden={{this.isClosed}} {{on "keydown" this.menuKeyDown}}>
            {{yield}}
            {{#if this.ready}}{{#if this.canCopy}}
              <div class="wx-message-text-tools">
                <button type="button" class="wx-message-copy" disabled={{this.copying}} {{on "click" this.copyBody}}>{{this.copyLabel}}</button>
                <button type="button" class="wx-message-select-text" {{on "click" this.selectText}}>选择文字</button>
              </div>
            {{/if}}{{/if}}
            {{#if this.copyError}}<p class="wx-message-copy-error" role="status">复制未完成，可点“选择文字”后复制。</p>{{/if}}
          </div>
          {{#if this.copied}}<span class="sr-only" role="status">已复制</span>{{/if}}
          {{#if this.isSelecting}}<div class="wx-message-selection-tools" role="status"><span>拖动选取文字，可使用系统复制</span><button type="button" {{on "click" this.endTextSelection}}>完成</button></div>{{/if}}
        </div>
      {{else}}{{yield}}{{/if}}
    </template>
  }

  class MessageEdit extends Component {
    @tracked raw = "";
    @tracked loading = true;
    @tracked saving = false;
    @tracked error = "";
    element = null;
    get disabled() { return this.loading || this.saving || !this.raw.trim(); }
    constructor() {
      super(...arguments);
      this.load();
    }
    async load() {
      try {
        const result = await ajax(`/posts/${this.args.post.id}.json`);
        if (this.isDestroying || this.isDestroyed) return;
        if (typeof result.raw !== "string") throw new Error("消息正文不可用，请取消后重试。");
        this.raw = result.raw;
        this.loading = false;
      } catch (error) {
        if (!this.isDestroying && !this.isDestroyed) {
          this.error = extractError(error, "消息加载失败，请取消后重试。");
        }
      }
    }
    @action setup(element) { this.element = element; }
    @action input(event) { if (!this.saving) this.raw = event.target.value; }
    @action cancel() { if (!this.saving) this.args.onClose(); }
    @action async save() {
      if (this.disabled) return;
      this.saving = true;
      this.error = "";
      let result;
      try {
        result = await ajax(`/posts/${this.args.post.id}.json`, {
          type: "PUT", data: { post: { raw: this.raw } },
        });
      } catch (error) {
        if (!this.isDestroying && !this.isDestroyed) {
          this.saving = false;
          this.error = extractError(error, "保存失败，修改内容已保留。");
        }
        return;
      }
      // The server has accepted the edit. Refresh display without mutating the
      // original post before success or presenting a failed-save retry afterward.
      if (result.post) this.args.post.setProperties(result.post);
      if (!this.isDestroying && !this.isDestroyed) this.args.onClose();
    }
    <template>
      <div class="wx-message-edit" {{didInsert this.setup}}>
        <div class="wx-edit-heading"><span>编辑消息</span><button type="button" disabled={{this.saving}} {{on "click" this.cancel}}>取消</button></div>
        {{#if this.error}}<div class="wx-send-error" role="alert">{{this.error}}</div>{{/if}}
        {{#if this.loading}}{{#unless this.error}}<p role="status">正在读取消息…</p>{{/unless}}{{else}}
          <textarea class="wx-edit-input" aria-label="编辑消息内容" value={{this.raw}} readonly={{this.saving}} {{on "input" this.input}}></textarea>
          <button type="button" class="wx-edit-save" disabled={{this.disabled}} {{on "click" this.save}}>{{if this.saving "保存中…" "保存"}}</button>
        {{/if}}
      </div>
    </template>
  }

  class InlineReply extends Component {
    @service currentUser;
    @service store;
    @service appEvents;
    @service keyValueStore;
    @tracked sending = false;
    @tracked error = "";
    @tracked notice = "";
    @tracked replyContext = null;
    @tracked editPost = null;
    @tracked composerRevision = 0;
    @tracked narrow = window.innerWidth < 900;
    openedAt = Date.now();
    typingMs = 0;
    lastInputAt = 0;
    composing = false;
    element = null;
    composerApi = null;
    resizeObserver = null;

    get topic() { return this.args.topic; }
    get draftKey() { return `wx-reply-v2-${this.currentUser.id}-${this.topic.id}`; }
    get contextKey() { return `${this.draftKey}-context`; }
    get canReply() { return Boolean(this.topic?.details?.can_create_post); }
    get composerInstances() { return [{ id: this.composerRevision }]; }
    get enterToSend() { return !this.narrow; }
    get dockClass() { return this.sending ? "wx-reply-dock wx-inline-composer is-sending" : "wx-reply-dock wx-inline-composer"; }

    constructor() {
      super(...arguments);
      this.sending = pendingReplies.has(this.draftKey);
      try { this.replyContext = JSON.parse(this.keyValueStore.get(this.contextKey) || "null"); } catch { /* Ignore a damaged local draft context. */ }
      this.appEvents.on("wx:reply-to-post", this, this.selectReply);
      this.appEvents.on("topic:edit-post", this, this.selectEdit);
      this.appEvents.on("topic:quote-post", this, this.selectQuote);
      this.appEvents.on("wx:reply-send-finished", this, this.sendFinished);
      registerDestructor(this, () => {
        this.appEvents.off("wx:reply-to-post", this, this.selectReply);
        this.appEvents.off("topic:edit-post", this, this.selectEdit);
        this.appEvents.off("topic:quote-post", this, this.selectQuote);
        this.appEvents.off("wx:reply-send-finished", this, this.sendFinished);
        this.resizeObserver?.disconnect();
        window.visualViewport?.removeEventListener("resize", this.updateViewport);
        window.visualViewport?.removeEventListener("scroll", this.updateViewport);
        window.removeEventListener("resize", this.updateViewport);
        this.element?.removeEventListener("keydown", this.guardInput, true);
        this.element?.removeEventListener("beforeinput", this.guardBeforeInput, true);
        this.element?.removeEventListener("paste", this.guardUpload, true);
        this.element?.removeEventListener("drop", this.guardUpload, true);
        this.element?.removeEventListener("click", this.guardUpload, true);
        this.element?.removeEventListener("input", this.recordInput);
        this.element?.removeEventListener("compositionstart", this.startComposition);
        this.element?.removeEventListener("compositionend", this.endComposition);
        this.element?.removeEventListener("focusin", this.updateViewport);
        this.element?.removeEventListener("focusout", this.updateViewport);
        document.body.style.removeProperty("--wx-keyboard-offset");
        document.body.style.removeProperty("--wx-dock-height");
        this.element = null;
      });
    }

    @action setup(element) {
      this.element = element;
      this.resizeObserver = new ResizeObserver(this.updateViewport);
      this.resizeObserver.observe(element);
      window.visualViewport?.addEventListener("resize", this.updateViewport);
      window.visualViewport?.addEventListener("scroll", this.updateViewport);
      window.addEventListener("resize", this.updateViewport);
      element.addEventListener("keydown", this.guardInput, true);
      element.addEventListener("beforeinput", this.guardBeforeInput, true);
      element.addEventListener("paste", this.guardUpload, true);
      element.addEventListener("drop", this.guardUpload, true);
      element.addEventListener("click", this.guardUpload, true);
      element.addEventListener("input", this.recordInput);
      element.addEventListener("compositionstart", this.startComposition);
      element.addEventListener("compositionend", this.endComposition);
      element.addEventListener("focusin", this.updateViewport);
      element.addEventListener("focusout", this.updateViewport);
      this.lockInput(this.sending);
      this.updateViewport();
    }

    @action updateViewport() {
      if (!this.element || this.isDestroying || this.isDestroyed) return;
      this.narrow = window.innerWidth < 900;
      const viewport = window.visualViewport;
      const focused = this.element.contains(document.activeElement);
      const offset = this.narrow && focused && viewport
        ? Math.max(0, window.innerHeight - viewport.height - viewport.offsetTop) : 0;
      document.body.style.setProperty("--wx-keyboard-offset", `${Math.round(offset)}px`);
      document.body.style.setProperty("--wx-dock-height", `${Math.ceil(this.element.getBoundingClientRect().height)}px`);
    }

    @action registerComposer(composerApi) { this.composerApi = composerApi; }
    @action startComposition() { this.composing = true; }
    @action endComposition() { this.composing = false; }
    @action guardBeforeInput(event) { if (this.sending) event.preventDefault(); }
    @action guardUpload(event) {
      if (!this.sending) return;
      // Uppy handles file paste directly, without a beforeinput event.
      if (event.type !== "click" || event.target.closest?.(".d-editor-button-bar, .docked-composer__uploads, input[type=file]")) {
        event.preventDefault();
        event.stopPropagation();
      }
    }
    @action guardInput(event) {
      if (event.key === "Enter" && (event.isComposing || this.composing || event.keyCode === 229)) {
        // Let the browser finish the IME candidate, but do not run editor send shortcuts.
        event.stopPropagation();
      }
    }
    @action recordInput() {
      const now = Date.now();
      if (this.lastInputAt) this.typingMs += Math.min(now - this.lastInputAt, 5000);
      this.lastInputAt = now;
      this.error = "";
      this.notice = "";
    }
    lockInput(locked) {
      const input = this.element?.querySelector(".d-editor-input");
      if (input?.tagName === "TEXTAREA") input.readOnly = locked;
      else if (input) input.setAttribute("contenteditable", locked ? "false" : "true");
      this.element?.querySelectorAll("input[type=file]").forEach((fileInput) => { fileInput.disabled = locked; });
    }

    @action selectEdit(request) {
      const post = request.post;
      if (post?.topic_id !== this.topic.id || post.post_type !== 1 || !post.can_edit || post.is_localized || !this.element) return;
      request.handled = true;
      if (this.sending || this.editPost) return;
      this.editPost = post;
    }
    @action closeEdit() { this.editPost = null; }

    @action selectReply(request) {
      if (request.topic?.id !== this.topic.id || !this.canReply || !this.element) return;
      request.handled = true;
      api.container.lookup("controller:topic").quoteState?.clear();
      // Busy replies still belong to this dock; never fall back to the old editor.
      if (this.sending || this.editPost) return;
      const post = request.post;
      this.replyContext = post ? {
        id: post.id, postNumber: post.post_number,
        name: post.name || post.display_username || post.username,
        excerpt: new DOMParser().parseFromString(post.cooked || "", "text/html").body.textContent.trim().slice(0, 90),
      } : null;
      this.persistContext();
      this.composerApi?.focus();
    }
    @action selectQuote(request) {
      if (!request.post || request.post.topic_id !== this.topic.id || request.post.post_type !== 1) return;
      const replyRequest = { ...request, topic: this.topic, handled: false };
      this.selectReply(replyRequest);
      request.handled = replyRequest.handled;
    }
    persistContext() {
      if (this.replyContext) this.keyValueStore.set({ key: this.contextKey, value: JSON.stringify(this.replyContext) });
      else this.keyValueStore.remove(this.contextKey);
    }
    @action clearReply() { this.replyContext = null; this.persistContext(); }
    @action reportError(error) { this.error = extractError(error, "发送未完成，内容已保留，请检查网络后再试。"); }

    @action sendFinished({ pending, post, result, error, clearOwner }) {
      if (pending.key !== this.draftKey || this.isDestroying || this.isDestroyed) return;
      this.sending = false;
      this.lockInput(false);
      if (error) {
        this.reportError(error);
        return;
      }
      try { this.replyContext = JSON.parse(this.keyValueStore.get(this.contextKey) || "null"); } catch { this.replyContext = null; }
      this.typingMs = 0;
      this.lastInputAt = 0;
      this.openedAt = Date.now();
      if (!clearOwner || pending.owner !== this) {
        // A new outlet can be displaying the pending draft. Reload only after
        // matching saved text was cleared, preserving any newer local draft.
        this.composerApi = null;
        this.composerRevision++;
      }
      if (result.responseJson?.action === "enqueued") {
        this.notice = "已提交，审核通过后会显示。";
      } else {
        this.showSentPost(post);
      }
    }

    @action async showSentPost(post) {
      const topic = this.topic;
      if (api.container.lookup("controller:topic").model?.id !== topic.id) return;
      this.appEvents.trigger("post:created", post);
      try {
        await topic.postStream.triggerNewPostsInStream([post.id]);
        if (!this.isDestroying && !this.isDestroyed && api.container.lookup("controller:topic").model?.id === topic.id) {
          DiscourseURL.routeTo(topic.urlForPostNumber(post.post_number));
        }
      } catch {
        if (!this.isDestroying && !this.isDestroyed) this.notice = "已发送，刷新话题即可查看。";
      }
    }

    @action async submit({ raw, uploads, inProgressUploadsCount }) {
      // Synchronous lock also covers rapid clicks before a Glimmer re-render.
      if (this.editPost || this.sending || pendingReplies.has(this.draftKey) || inProgressUploadsCount || !this.canReply) return false;
      const body = [raw.trim(), ...uploads.map((upload) => getUploadMarkdown(upload))].filter(Boolean).join("\n\n");
      if (!body) return false;
      const pending = {
        key: this.draftKey, contextKey: this.contextKey, raw,
        context: this.keyValueStore.get(this.contextKey), owner: this,
      };
      pendingReplies.set(pending.key, pending);
      this.sending = true;
      this.error = "";
      this.notice = "";
      this.lockInput(true);
      const topic = this.topic;
      const post = this.store.createRecord("post", {
        raw: body, topic_id: topic.id,
        reply_to_post_number: this.replyContext?.postNumber,
        draft_key: `wx_topic_${topic.id}`,
        typing_duration_msecs: this.typingMs,
        composer_open_duration_msecs: Date.now() - this.openedAt,
      });
      let result;
      try {
        result = await post.save();
      } catch (error) {
        pendingReplies.delete(pending.key);
        this.appEvents.trigger("wx:reply-send-finished", { pending, error });
        return false;
      }
      // The server accepted it. A stream refresh failure must never become a second send.
      const savedDraft = this.keyValueStore.get(pending.key);
      const sameDraft = savedDraft === pending.raw;
      if (sameDraft) this.keyValueStore.remove(pending.key);
      if ((sameDraft || savedDraft === null) && this.keyValueStore.get(pending.contextKey) === pending.context) {
        this.keyValueStore.remove(pending.contextKey);
      }
      const clearOwner = !this.isDestroying && !this.isDestroyed && (sameDraft || savedDraft === null);
      pendingReplies.delete(pending.key);
      this.appEvents.trigger("wx:reply-send-finished", { pending, post, result, clearOwner });
      if (result.responseJson?.action !== "enqueued") this.appEvents.trigger("wx:message-sent", post);
      // Only a still-mounted owner with the original draft may let the core
      // composer clear its input/uploads. An obsolete instance must not clear
      // the localStorage key belonging to a newly mounted composer.
      return clearOwner;
    }

    <template>
      <div class={{this.dockClass}} {{didInsert this.setup}}>
        {{#if this.editPost}}<MessageEdit @post={{this.editPost}} @onClose={{this.closeEdit}} />{{/if}}
        <div class="wx-reply-normal" hidden={{this.editPost}}>
        {{#if this.error}}<div class="wx-send-error" role="alert">{{this.error}}</div>{{/if}}
        {{#if this.notice}}<div class="wx-send-notice" role="status">{{this.notice}}</div>{{/if}}
        {{#if this.canReply}}
          {{#each this.composerInstances key="id"}}
          <DockedComposer
            @class="wx-docked-composer"
            @topicId={{this.topic.id}} @categoryId={{this.topic.category_id}}
            @draftKey={{this.draftKey}} @autoResize={{true}}
            @composerEvents={{false}} @submitOnEnter={{this.enterToSend}}
            @placeholder="说点什么…" @onSubmit={{this.submit}}
            @onRegisterApi={{this.registerComposer}} @onError={{this.reportError}}
            @isSubmitting={{this.sending}} @disabled={{this.sending}}
          >
            <:header>
              {{#if this.replyContext}}<div class="wx-reply-context"><span>回复 <strong>{{this.replyContext.name}}</strong>：{{this.replyContext.excerpt}}</span><button type="button" aria-label="取消引用" disabled={{this.sending}} {{on "click" this.clearReply}}>×</button></div>{{/if}}
            </:header>
            <:submit as |ctx|><DButton class="wx-send" @translatedLabel={{if this.sending "发送中" "发送"}} @action={{ctx.submit}} @disabled={{ctx.disabled}} /></:submit>
          </DockedComposer>
          {{/each}}
        {{else}}<span class="wx-closed">这个话题暂时不能回复</span>{{/if}}
        </div>
      </div>
    </template>
  }

  class ReplyDock extends Component {
    @service currentUser;
    @tracked toolsOpen = false;
    @tracked copied = false;
    get topic() { return this.args.outletArgs.model; }
    get topics() { return this.topic?.archetype === "regular" ? [this.topic] : []; }
    get introductionUrl() { return `/t/${this.topic.slug || "topic"}/${this.topic.id}/1`; }
    get latestUrl() { return `/t/${this.topic.slug || "topic"}/${this.topic.id}/${this.topic.highest_post_number || 1}`; }
    @action introduction(event) {
      if (event.button || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
      event.preventDefault();
      this.toolsOpen = false;
      DiscourseURL.routeTo(this.introductionUrl);
    }
    @action login() { api.container.lookup("route:application").send("showLogin"); }
    @action latest(event) {
      if (event.button || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
      event.preventDefault();
      this.toolsOpen = false;
      DiscourseURL.routeTo(this.latestUrl);
    }
    @action toggleTools() { this.toolsOpen = !this.toolsOpen; this.copied = false; }
    @action async copyTopic() {
      try { await clipboardCopy(`${window.location.origin}/t/${this.topic.slug || "topic"}/${this.topic.id}`); this.copied = true; }
      catch { this.copied = false; }
    }
    <template>
      <div class="wx-chat-heading"><span role="heading" aria-level="1" title={{this.topic.title}}>{{this.topic.title}}</span><button type="button" aria-label="话题更多操作" aria-expanded={{this.toolsOpen}} {{on "click" this.toggleTools}}>•••</button>
        {{#if this.toolsOpen}}<nav class="wx-topic-menu" aria-label="话题操作"><a href={{this.introductionUrl}} {{on "click" this.introduction}}>回到开头</a><a href={{this.latestUrl}} {{on "click" this.latest}}>跳到最新</a><button type="button" {{on "click" this.copyTopic}}>{{if this.copied "链接已复制" "分享话题"}}</button></nav>{{/if}}
      </div>
      {{#each this.topics key="id" as |topic|}}
        {{#if this.currentUser}}<InlineReply @topic={{topic}} />{{else}}<div class="wx-reply-dock"><button type="button" class="wx-reply-input" {{on "click" this.login}}>登录后参与讨论</button></div>{{/if}}
      {{/each}}
    </template>
  }

  api.modifyClass("controller:topic", (Superclass) => class extends Superclass {
    @action replyToPost(post) {
      const topic = post ? post.get("topic") : this.model;
      const composer = this.composer?.model;
      const ordinary = topic?.archetype === "regular" && (!post || post.post_type === 1);
      const conflictingComposer = composer && (composer.whisper || (composer.action && composer.action !== "reply"));
      if (ordinary && !conflictingComposer && topic.id === this.model?.id) {
        const request = { topic, post, handled: false };
        this.appEvents.trigger("wx:reply-to-post", request);
        if (request.handled) return false;
      }
      return super.replyToPost(post);
    }
  });
  api.renderInOutlet("before-main-outlet", Conversations);
  api.renderInOutlet("topic-above-post-stream", ReplyDock);
  // Only our touch messages use the native text-selection menu by itself.
  // The core retains its usual quoting toolbar for desktop mouse selection.
  api.modifyClass("component:post-text-selection", (Superclass) => class extends Superclass {
    wxSuppressesToolbar(cooked) {
      const post = cooked?.closest(".topic-post");
      return post?.dataset.wxMessageActions === "true" && (post.dataset.wxPointerMode === "touch" || post.dataset.wxSelecting === "true");
    }

    computeCurrentCooked() {
      const cooked = super.computeCurrentCooked();
      return this.wxSuppressesToolbar(cooked) ? undefined : cooked;
    }

    async showToolbar(cooked) {
      if (this.wxSuppressesToolbar(cooked)) return this.hideToolbar();
      try {
        await super.showToolbar(cooked);
      } catch (error) {
        // A touch-mode switch can clear a selection while the core awaits its
        // fast-edit check. Only swallow that now-obsolete selection request.
        if (!this.wxSuppressesToolbar(cooked)) throw error;
      }
      if (this.wxSuppressesToolbar(cooked)) await this.hideToolbar();
    }
  });
  api.registerValueTransformer("post-menu-buttons", ({ value, context }) => {
    if (context.state.nestedReplyView || !/^\/t\//.test(api.container.lookup("service:router").currentURL || "")) return;
    value.delete(context.buttonKeys.COPY_LINK);
    value.delete(context.buttonKeys.BOOKMARK);
    value.delete(context.buttonKeys.SHARE);
    // Only presentation changes: the core still decides which actions exist,
    // whether they are enabled, and what confirmation or login they require.
    for (const key of Object.values(context.buttonKeys)) {
      context.buttonLabels.show(key);
      context.collapsedButtons.show(key);
    }
  });
  api.renderInOutlet("post-menu", MessageActions);
});
