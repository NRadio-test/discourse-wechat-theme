import Component from "@glimmer/component";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { on } from "@ember/modifier";
import { apiInitializer } from "discourse/lib/api";
import DiscourseURL from "discourse/lib/url";

// Keep core identity visibility, suspension notices and staff controls. Only
// add a clear profile link and dismiss action to the existing card.
class ProfileActions extends Component {
  @service currentUser;
  get visible() { return document.body.classList.contains("wx-forum"); }
  get user() { return this.args.outletArgs.user; }
  get canViewProfile() { return this.user && !this.user.profile_hidden && !this.user.inactive; }
  get own() { return this.currentUser?.id === this.user?.id; }
  get destination() { return this.user?.path ? `${this.user.path}/summary` : null; }
  @action close() { this.args.outletArgs.close(); }
  @action viewProfile(event) {
    if (event.button || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    event.preventDefault();
    const destination = this.destination;
    if (!this.canViewProfile || !destination) return;
    this.close();
    // Core clears the card's user while closing. Capture the URL first.
    DiscourseURL.routeTo(destination);
  }
  <template>
    {{#if this.visible}}
    <li class="wx-profile-actions">
      {{#if this.canViewProfile}}<a class="wx-profile-view" href={{this.destination}} {{on "click" this.viewProfile}}>{{if this.own "我" "查看资料"}}</a>{{/if}}
      <button type="button" class="wx-profile-close" {{on "click" this.close}}>关闭</button>
    </li>
    {{/if}}
  </template>
}

export default apiInitializer("1.0", (api) => {
  api.renderInOutlet("user-card-below-message-button", ProfileActions);
});
