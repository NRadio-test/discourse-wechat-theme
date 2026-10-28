import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { registerDestructor } from "@ember/destroyable";
import { on } from "@ember/modifier";
import didUpdate from "@ember/render-modifiers/modifiers/did-update";
import { apiInitializer } from "discourse/lib/api";
import DiscourseURL from "discourse/lib/url";

function postNumber(value) {
  const number = Number(value);
  return Number.isSafeInteger(number) && number > 0 ? number : null;
}

class ChatNavigation extends Component {
  @service appEvents;
  @service currentUser;
  @service keyValueStore;
  @tracked away = false;
  @tracked seenLatest = this.args.topic.highest_post_number || 1;
  @tracked returnTo = null;
  frame = null;
  get topic() { return this.args.topic; }
  get hasNew() { return this.topic.highest_post_number > this.seenLatest; }

  constructor() {
    super(...arguments);
    this.appEvents.on("topic:current-post-changed", this, this.readPost);
    this.appEvents.on("wx:jump-to-reply", this, this.jumpToReply);
    // Post-stream updates and viewport movement use the same bounded check.
    this.appEvents.on("topic:current-post-scrolled", this, this.scheduleCheck);
    document.addEventListener("scroll", this.scheduleCheck, { passive: true, capture: true });
    window.addEventListener("resize", this.scheduleCheck);
    window.visualViewport?.addEventListener("resize", this.scheduleCheck);
    this.scheduleCheck();
    registerDestructor(this, () => {
      this.appEvents.off("topic:current-post-changed", this, this.readPost);
      this.appEvents.off("wx:jump-to-reply", this, this.jumpToReply);
      this.appEvents.off("topic:current-post-scrolled", this, this.scheduleCheck);
      document.removeEventListener("scroll", this.scheduleCheck, true);
      window.removeEventListener("resize", this.scheduleCheck);
      window.visualViewport?.removeEventListener("resize", this.scheduleCheck);
      if (this.frame !== null) cancelAnimationFrame(this.frame);
    });
  }

  @action readPost({ post }) {
    if (post?.topic_id !== this.topic.id) return;
    const number = postNumber(post.post_number);
    if (number) {
      try { this.keyValueStore.set({ key: `wx-read-${this.currentUser?.id || "guest"}-${this.topic.id}`, value: number }); }
      catch { /* A full or disabled browser store must not interrupt reading. */ }
    }
    this.scheduleCheck();
  }

  @action scheduleCheck() {
    if (this.frame !== null || this.isDestroying || this.isDestroyed) return;
    this.frame = requestAnimationFrame(() => {
      this.frame = null;
      if (this.isDestroying || this.isDestroyed) return;
      const last = document.getElementById(`post_${this.topic.highest_post_number}`);
      const rect = last?.getBoundingClientRect();
      const viewport = window.visualViewport;
      const bottom = (viewport?.height || window.innerHeight) + (viewport?.offsetTop || 0);
      const dock = document.querySelector(".wx-reply-dock")?.getBoundingClientRect();
      const available = dock && dock.top > 0 ? Math.min(bottom, dock.top) : bottom - 72;
      this.away = !rect || rect.bottom > available + 32;
      if (!this.away) this.seenLatest = this.topic.highest_post_number;
    });
  }

  @action jumpToReply({ topicId, from, to }) {
    if (topicId !== this.topic.id || !postNumber(from) || !postNumber(to) || to > this.topic.highest_post_number) return;
    this.returnTo = from;
    DiscourseURL.routeTo(this.topic.urlForPostNumber(to));
  }
  @action goBack() {
    const number = postNumber(this.returnTo);
    this.returnTo = null;
    if (number) DiscourseURL.routeTo(this.topic.urlForPostNumber(number));
  }
  @action goLatest() {
    this.returnTo = null;
    DiscourseURL.routeTo(this.topic.urlForPostNumber(this.topic.highest_post_number));
  }
  <template>
    <div class="wx-chat-position" aria-label="聊天位置" {{didUpdate this.scheduleCheck this.topic.highest_post_number}}>
      {{#if this.returnTo}}<button type="button" {{on "click" this.goBack}}>↩ 回到刚才</button>{{/if}}
      {{#if this.away}}<button type="button" {{on "click" this.goLatest}}>{{if this.hasNew "有新消息 ↓" "回到最新 ↓"}}</button>{{/if}}
    </div>
  </template>
}

class NavigationOutlet extends Component {
  get topics() {
    const topic = this.args.outletArgs?.model;
    return topic?.archetype === "regular" ? [topic] : [];
  }
  <template>{{#each this.topics key="id" as |topic|}}<ChatNavigation @topic={{topic}} />{{/each}}</template>
}

class ReplyReference extends Component {
  @service appEvents;
  get name() { return this.args.post.reply_to_user?.name || "这条消息"; }
  @action jump(event) {
    event.preventDefault();
    this.appEvents.trigger("wx:jump-to-reply", {
      topicId: this.args.post.topic_id,
      from: this.args.post.post_number,
      to: this.args.post.reply_to_post_number,
    });
  }
  <template><button class="wx-reply-reference" type="button" title="查看回复的消息" {{on "click" this.jump}}>↩ {{this.name}}</button></template>
}

export default apiInitializer("1.0", (api) => {
  api.renderInOutlet("topic-above-post-stream", NavigationOutlet);
  api.registerValueTransformer("post-meta-data-infos", ({ value, context }) => {
    const topic = api.container.lookup("controller:topic")?.model;
    if (topic?.archetype === "regular" && topic.id === context.post.topic_id && postNumber(context.post.reply_to_post_number)) {
      value.replace(context.metaDataInfoKeys.REPLY_TO_TAB, ReplyReference);
    }
    return value;
  });
});
