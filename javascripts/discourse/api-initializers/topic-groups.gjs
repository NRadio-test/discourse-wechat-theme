import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { registerDestructor } from "@ember/destroyable";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { getOwner } from "@ember/owner";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import { next } from "@ember/runloop";
import { service } from "@ember/service";
import { apiInitializer } from "discourse/lib/api";
import { extractError } from "discourse/lib/ajax-error";
import DiscourseURL from "discourse/lib/url";
import { getUploadMarkdown } from "discourse/lib/uploads";
import { defaultHomepage } from "discourse/lib/utilities";
import UppyUpload from "discourse/lib/uppy/uppy-upload";
import Category from "discourse/models/category";
import { CREATE_TOPIC } from "discourse/models/composer";
import DButton from "discourse/ui-kit/d-button";
import DModal from "discourse/ui-kit/d-modal";

// A modal may be replaced while a request is in flight. Keep its submission
// lock outside the component so reopening cannot submit the same draft twice.
const pendingTopics = new Map();
const UPLOAD_FIELDS = ["id", "url", "short_url", "original_filename", "thumbnail_width", "thumbnail_height", "filesize"];

function draftUpload(upload) {
  return Object.fromEntries(UPLOAD_FIELDS.filter((key) => upload[key] !== undefined).map((key) => [key, upload[key]]));
}

class TopicGroupModal extends Component {
  @service appEvents;
  @service currentUser;
  @service keyValueStore;
  @service site;
  @service siteSettings;
  @service store;

  @tracked title = "";
  @tracked body = "";
  @tracked uploads = [];
  @tracked category = null;
  @tracked loadingCategory = true;
  @tracked sending = false;
  @tracked error = "";
  @tracked notice = "";
  @tracked categoryError = "";
  typingMs = 0;
  lastInputAt = 0;
  openedAt = Date.now();
  inputElement = null;
  uploader = null;
  accepted = false;

  constructor() {
    super(...arguments);
    this.restoreDraft();
    if (!this.title && !this.body && !this.uploads.length) {
      this.title = this.args.model.title || "";
      this.body = this.args.model.body || "";
    }
    this.sending = pendingTopics.has(this.draftKey);
    this.appEvents.on("wx:topic-create-finished", this, this.finishSubmission);
    this.uploader = new UppyUpload(getOwner(this), {
      id: `wx-new-topic-${this.currentUser.id}`,
      type: "composer",
      useMultipartUploadsIfAvailable: true,
      validateUploadedFilesOptions: { imagesOnly: true, bypassNewUserRestriction: false },
      uploadDone: (upload) => {
        if (this.isDestroying || this.isDestroyed) return;
        this.accepted = false;
        this.uploads = [...this.uploads, draftUpload(upload)];
        this.persistDraft();
      },
    });
    registerDestructor(this, () => {
      this.persistDraft();
      this.appEvents.off("wx:topic-create-finished", this, this.finishSubmission);
      this.uploader?.teardown();
    });
    this.loadCategory();
  }

  get draftKey() { return `wx-new-topic-v1-${this.currentUser.id}`; }
  get minimumTitleLength() { return this.siteSettings.min_topic_title_length || 2; }
  get maximumTitleLength() { return this.siteSettings.max_topic_title_length || 255; }
  get inProgressUploads() { return this.uploader?.inProgressUploads || []; }
  get uploading() { return this.inProgressUploads.length > 0 || this.uploader?.processing || this.uploader?.uploading; }
  get busy() { return this.sending || this.uploading; }
  get canDismiss() { return !this.busy; }
  get canCreate() {
    return this.currentUser?.can_create_topic && !this.site.isReadOnly &&
      this.category?.read_restricted === false && this.category?.canCreateTopic;
  }
  get submitDisabled() { return this.busy || this.loadingCategory || !this.canCreate || !this.title.trim(); }
  get inputDisabled() { return this.sending || this.loadingCategory || !this.canCreate; }

  async loadCategory() {
    const categoryId = Number(this.args.model.categoryId);
    try {
      if (!Number.isSafeInteger(categoryId) || categoryId <= 0) {
        this.categoryError = "暂时不能发起话题，请稍后再试。";
        return;
      }
      const category = await Category.asyncFindById(categoryId);
      if (this.isDestroying || this.isDestroyed) return;
      // Never infer a category from the current topic, a URL, or a private area.
      if (!category || category.read_restricted !== false || !category.canCreateTopic) {
        this.categoryError = "暂时不能发起话题，请联系管理员。";
        return;
      }
      this.category = category;
      if (!this.currentUser.can_create_topic || this.site.isReadOnly) {
        this.categoryError = "当前账号暂时不能发起话题。";
      }
    } catch {
      if (!this.isDestroying && !this.isDestroyed) this.categoryError = "暂时无法加载，请关闭后重试。";
    } finally {
      if (!this.isDestroying && !this.isDestroyed) this.loadingCategory = false;
    }
  }

  restoreDraft() {
    try {
      const draft = JSON.parse(this.keyValueStore.get(this.draftKey) || "null");
      if (!draft || typeof draft !== "object") return;
      this.title = typeof draft.title === "string" ? draft.title : "";
      this.body = typeof draft.body === "string" ? draft.body : "";
      this.uploads = Array.isArray(draft.uploads) ? draft.uploads.filter((upload) =>
        upload && typeof upload.original_filename === "string" && typeof upload.short_url === "string"
      ).map(draftUpload) : [];
      this.typingMs = Number.isFinite(draft.typingMs) && draft.typingMs >= 0 ? draft.typingMs : 0;
    } catch {
      this.error = "上次草稿无法读取，请重新填写。";
    }
  }

  serializeDraft() {
    return JSON.stringify({ title: this.title, body: this.body, uploads: this.uploads, typingMs: this.typingMs });
  }

  persistDraft() {
    if (this.accepted) return;
    if (this.title || this.body || this.uploads.length) {
      this.keyValueStore.set({ key: this.draftKey, value: this.serializeDraft() });
    } else {
      this.keyValueStore.remove(this.draftKey);
    }
  }

  recordTyping() {
    const now = Date.now();
    // Count only observed input activity; never turn time spent waiting in the
    // modal, uploading, or a closed draft into fake typing duration.
    if (this.lastInputAt && now - this.lastInputAt <= 2000) this.typingMs += now - this.lastInputAt;
    this.lastInputAt = now;
    this.error = "";
    this.notice = "";
    this.accepted = false;
  }

  @action changeTitle(event) {
    if (this.sending) return;
    if (event.inputType?.startsWith("insertFrom")) this.lastInputAt = 0;
    this.title = event.target.value;
    this.recordTyping();
    this.persistDraft();
  }
  @action changeBody(event) {
    if (this.sending) return;
    if (event.inputType?.startsWith("insertFrom")) this.lastInputAt = 0;
    this.body = event.target.value;
    this.recordTyping();
    this.persistDraft();
  }
  @action compositionStart() {
    if (this.sending) return;
    this.lastInputAt = 0;
    this.recordTyping();
  }
  @action compositionUpdate() {
    if (!this.sending) this.recordTyping();
  }
  @action compositionEnd() {
    if (this.sending) return;
    this.recordTyping();
    this.lastInputAt = 0;
    this.persistDraft();
  }
  @action resetTypingActivity() { this.lastInputAt = 0; }
  @action registerFileInput(element) { this.inputElement = element; this.uploader.setup(element); }
  @action chooseImages() {
    this.resetTypingActivity();
    if (!this.sending && this.canCreate) this.inputElement?.click();
  }
  @action removeUpload(upload) {
    if (this.sending) return;
    this.accepted = false;
    this.uploads = this.uploads.filter((item) => item !== upload);
    this.persistDraft();
  }
  @action cancelUpload(upload) { this.uploader?.cancelSingleUpload({ fileId: upload.id }); }
  @action pasteImages(event) {
    const files = [...(event.clipboardData?.files || [])].filter((file) => file.type.startsWith("image/"));
    if (!files.length) return;
    this.resetTypingActivity();
    event.preventDefault();
    if (!this.sending && this.canCreate) this.uploader?.addFiles(files, { pasted: true });
  }
  @action shortcut(event) {
    if (event.key === "Enter" && !event.isComposing && event.keyCode !== 229 && (event.metaKey || event.ctrlKey)) {
      event.preventDefault();
      this.submit();
    }
  }
  @action beforeClose() { this.resetTypingActivity(); this.persistDraft(); return !this.busy; }
  @action close() { if (this.beforeClose()) this.args.closeModal(); }

  @action async submit() {
    if (this.submitDisabled || pendingTopics.has(this.draftKey)) return false;
    const title = this.title.trim();
    if (title.length < this.minimumTitleLength || title.length > this.maximumTitleLength) {
      this.error = `话题名称需要 ${this.minimumTitleLength}–${this.maximumTitleLength} 个字。`;
      return false;
    }
    const content = [this.body.trim(), ...this.uploads.map(getUploadMarkdown)].filter(Boolean).join("\n\n");
    const raw = content || title;
    const minimumBody = this.siteSettings.min_first_post_length || 1;
    if (raw.length < minimumBody) {
      this.error = `请补充一点开场内容，至少 ${minimumBody} 个字。`;
      return false;
    }
    this.persistDraft();
    const pending = { key: this.draftKey, snapshot: this.keyValueStore.get(this.draftKey) };
    pendingTopics.set(pending.key, pending);
    this.sending = true;
    this.error = "";
    this.notice = "";
    let post, result;
    try {
      post = this.store.createRecord("post", {
        title,
        raw,
        category: this.category.id,
        archetype: "regular",
        draft_key: `wx_new_topic_${this.currentUser.id}`,
        typing_duration_msecs: this.typingMs,
        composer_open_duration_msecs: Date.now() - this.openedAt,
      });
      result = await post.save();
    } catch (error) {
      pendingTopics.delete(pending.key);
      this.appEvents.trigger("wx:topic-create-finished", { pending, error });
      return false;
    }
    // Acceptance is final even if navigation later fails. Never retry a post
    // automatically after the server accepted or queued it.
    if (this.keyValueStore.get(pending.key) === pending.snapshot) this.keyValueStore.remove(pending.key);
    pendingTopics.delete(pending.key);
    this.appEvents.trigger("wx:topic-create-finished", { pending, post, result });
    return true;
  }

  @action finishSubmission({ pending, post, result, error }) {
    if (pending.key !== this.draftKey || this.isDestroying || this.isDestroyed) return;
    this.sending = false;
    if (error) {
      this.error = extractError(error, "没有发出去，草稿已保留，请稍后重试。");
      return;
    }
    this.accepted = true;
    this.title = "";
    this.body = "";
    this.uploads = [];
    this.typingMs = 0;
    this.lastInputAt = 0;
    this.openedAt = Date.now();
    if (result?.responseJson?.action === "enqueued") {
      this.notice = "话题已提交，审核通过后大家就能看到了。";
      return;
    }
    this.appEvents.trigger("wx:message-sent", post);
    if (!post?.topic_id) {
      this.notice = "话题已提交，刷新列表即可查看。";
      return;
    }
    this.args.closeModal();
    DiscourseURL.routeTo(`/t/topic/${post.topic_id}/${post.post_number || 1}`);
  }

  <template>
    <DModal @title="发起话题" @closeModal={{this.close}} @beforeClose={{this.beforeClose}} @dismissable={{this.canDismiss}} @submitOnEnter={{false}} class="wx-new-topic-modal">
      <:body>
        {{#if this.loadingCategory}}<p class="wx-topic-state" role="status">正在准备…</p>{{/if}}
        {{#if this.categoryError}}<p class="wx-topic-error" role="alert">{{this.categoryError}}</p>{{/if}}
        {{#if this.error}}<p class="wx-topic-error" role="alert">{{this.error}}</p>{{/if}}
        {{#if this.notice}}<p class="wx-topic-notice" role="status">{{this.notice}}</p>{{/if}}
        <div class="wx-topic-fields" {{on "keydown" this.shortcut}}>
          <label for="wx-topic-title">话题名称</label>
          <input id="wx-topic-title" class="wx-topic-title-input" type="text" autocomplete="off" placeholder="想和大家聊什么？" value={{this.title}} maxlength={{this.maximumTitleLength}} disabled={{this.inputDisabled}} {{on "input" this.changeTitle}} {{on "compositionstart" this.compositionStart}} {{on "compositionupdate" this.compositionUpdate}} {{on "compositionend" this.compositionEnd}} {{on "blur" this.resetTypingActivity}} />
          <label for="wx-topic-body">开场内容<span>（选填）</span></label>
          <textarea id="wx-topic-body" class="wx-topic-body-input" rows="4" placeholder="写几句，或放张图片。不填也能直接开始聊。" value={{this.body}} disabled={{this.inputDisabled}} {{on "input" this.changeBody}} {{on "paste" this.pasteImages}} {{on "compositionstart" this.compositionStart}} {{on "compositionupdate" this.compositionUpdate}} {{on "compositionend" this.compositionEnd}} {{on "blur" this.resetTypingActivity}}></textarea>
          <div class="wx-topic-images">
            {{#each this.uploads as |upload|}}
              <div class="wx-topic-image"><img src={{upload.url}} alt={{upload.original_filename}} /><button type="button" aria-label="移除图片" disabled={{this.sending}} {{on "click" (fn this.removeUpload upload)}}>×</button></div>
            {{/each}}
            {{#each this.inProgressUploads as |upload|}}
              <div class="wx-topic-uploading"><span>{{upload.fileName}}</span><span>{{upload.progress}}%</span><button type="button" aria-label="取消图片上传" {{on "click" (fn this.cancelUpload upload)}}>×</button></div>
            {{/each}}
          </div>
          <button type="button" class="wx-topic-add-image" disabled={{this.inputDisabled}} {{on "click" this.chooseImages}}><span aria-hidden="true">＋</span> 添加图片</button>
          <input class="wx-topic-file-input" type="file" accept="image/*" multiple disabled={{this.inputDisabled}} {{didInsert this.registerFileInput}} />
        </div>
        <p class="wx-topic-draft-note">关掉也没关系，草稿会留在这里。</p>
      </:body>
      <:footer>
        <DButton class="wx-topic-cancel" @translatedLabel="先放一放" @action={{this.close}} @disabled={{this.busy}} />
        <DButton class="btn-primary wx-topic-create" @translatedLabel={{if this.sending "发起中…" "发起话题"}} @action={{this.submit}} @disabled={{this.submitDisabled}} />
      </:footer>
    </DModal>
  </template>
}

export default apiInitializer("1.0", (api) => {
  const open = (prefill = {}) => {
    const currentUser = api.getCurrentUser();
    if (!currentUser) {
      api.container.lookup("route:application").send("showLogin");
      return;
    }
    const modal = api.container.lookup("service:modal");
    if (modal.activeModal?.component === TopicGroupModal) return;
    const siteSettings = api.container.lookup("service:site-settings");
    const configured = typeof settings !== "undefined" ? Number(settings.default_topic_category_id) : 0;
    const categoryId = configured > 0 ? configured : Number(siteSettings.default_composer_category);
    modal.show(TopicGroupModal, { model: {
      categoryId,
      title: typeof prefill.title === "string" ? prefill.title : "",
      body: typeof prefill.body === "string" ? prefill.body : "",
    } });
  };

  api.onAppEvent("wx:new-topic", open);
  // Native list buttons and keyboard shortcuts also create topics through this
  // service. Keep those entry points on the same minimal flow. Editing, private
  // messages, shared drafts and staff administration retain their own actions.
  api.modifyClass("service:composer", (Superclass) => class extends Superclass {
    async open(opts = {}) {
      // Outside the conversation shell, preserve the native context (including
      // a private category) instead of silently creating a public discussion.
      if (opts.action === CREATE_TOPIC && document.body.classList.contains("wx-forum") && !this.router.currentRouteName?.startsWith("admin")) {
        open({ title: opts.topicTitle, body: opts.topicBody });
        return;
      }
      return super.open(opts);
    }
  });
  api.modifyClass("route:new-topic", (Superclass) => class extends Superclass {
    beforeModel(transition) {
      // Never enter the legacy route or invoke its forum composer. Direct URLs
      // need a real background page; in-app clicks keep the current discussion.
      if (transition.from) {
        transition.abort();
        open();
        return;
      }
      this.router.replaceWith(`discovery.${defaultHomepage()}`).followRedirects().then(() => {
        // Match core new-topic's lifecycle: let the destination route finish
        // rendering and closing transient UI before opening the modal.
        next(open);
      });
    }
  });
});
