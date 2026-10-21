import Component from "@glimmer/component";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import { apiInitializer } from "discourse/lib/api";
import DiscourseURL from "discourse/lib/url";

// Keep core identity visibility, suspension notices and staff controls. Only
// add a clear profile link and dismiss action to the existing card.
class ProfileActions extends Component {
  get visible() { return document.body.classList.contains("wx-forum"); }
  get user() { return this.args.outletArgs.user; }
  get canViewProfile() { return this.user && !this.user.profile_hidden && !this.user.inactive; }
  @action close() { this.args.outletArgs.close(); }
  @action viewProfile(event) {
    if (event.button || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    event.preventDefault();
    this.close();
    DiscourseURL.routeTo(this.user.path);
  }
  <template>
    {{#if this.visible}}
    <li class="wx-profile-actions">
      {{#if this.canViewProfile}}<a class="wx-profile-view" href={{this.user.path}} {{on "click" this.viewProfile}}>查看资料</a>{{/if}}
      <button type="button" class="wx-profile-close" {{on "click" this.close}}>关闭</button>
    </li>
    {{/if}}
  </template>
}

export default apiInitializer("1.0", (api) => {
  api.renderInOutlet("user-card-below-message-button", ProfileActions);
});
