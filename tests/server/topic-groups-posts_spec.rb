# frozen_string_literal: true
# Run only inside an isolated Discourse checkout with RAILS_ENV=test:
# bundle exec rspec /path/to/theme/tests/server/topic-groups-posts_spec.rb
raise "This spec must run in RAILS_ENV=test" unless ENV["RAILS_ENV"] == "test"
require "rails_helper"

RSpec.describe "WeChat theme topic creation payload", type: :request do
  let(:writer) { Fabricate(:user, trust_level: 0, refresh_auto_groups: true) }
  let(:public_category) { Fabricate(:category, id: 4, name: "Synthetic public conversations") }

  before do
    # Synthetic database only. Match the short-message product settings without
    # pretending that a short Chinese title took longer to type than it did.
    SiteSetting.min_topic_title_length = 2
    SiteSetting.min_first_post_length = 1
    SiteSetting.min_post_length = 1
    SiteSetting.auto_silence_fast_typers_on_first_post = false
  end

  def payload(category_id: public_category.id, title: "开聊", raw: title)
    {
      title: title,
      raw: raw,
      category: category_id,
      archetype: "regular",
      draft_key: "wx_new_topic_#{writer.id}",
      typing_duration_msecs: 0,
      composer_open_duration_msecs: 0,
      nested_post: true,
    }
  end

  def send_payload(data = payload)
    post "/posts.json", params: data.to_json, headers: { "CONTENT_TYPE" => "application/json" }
  end

  it "accepts a two-character title as the opening post through the real PostAdapter JSON shape" do
    sign_in(writer)
    expect(public_category.read_restricted).to eq(false)
    before_count = Topic.count
    send_payload
    expect(response.status).to eq(200), response.body
    expect(Topic.count).to eq(before_count + 1)
    json = response.parsed_body
    expect(json["success"]).to eq(true)
    expect(json["action"]).to eq("create_post")
    expect(json.fetch("post").values_at("raw", "post_number", "topic_id")).to eq(["开聊", 1, Topic.last.id])
    topic = Topic.find(json.fetch("post").fetch("topic_id"))
    expect(topic.category_id).to eq(4)
    expect(topic.archetype).to eq("regular")
    expect(topic.tags).to be_empty
    expect(writer.reload).not_to be_silenced
  end

  it "keeps the normal approval result instead of inventing a published post" do
    sign_in(writer)
    public_category
    SiteSetting.approve_new_topics_unless_allowed_groups = Group::AUTO_GROUPS[:trust_level_4].to_s
    expect { send_payload }.not_to change { Topic.count }
    expect(response.status).to eq(200), response.body
    json = response.parsed_body
    expect(json["success"]).to eq(true)
    expect(json["action"]).to eq("enqueued")
    expect(json["post"]).to be_nil
    expect(json.dig("pending_post", "id")).to be_present
    queued = ReviewableQueuedPost.find(json.fetch("pending_post").fetch("id"))
    expect(queued.target_created_by_id).to eq(writer.id)
    expect(queued.category_id).to eq(4)
    expect(queued.payload.values_at("title", "raw", "typing_duration_msecs")).to eq(["开聊", "开聊", 0])
    expect(writer.reload).not_to be_silenced
  end

  it "rejects a category the user cannot access" do
    sign_in(writer)
    private_category = Fabricate(:private_category, group: Fabricate(:group))
    expect { send_payload(payload(category_id: private_category.id)) }.not_to change { Topic.count }
    expect(response.status).to be_in([403, 422]), response.body
    expect(response.parsed_body["errors"]).to be_present
  end

  it "keeps public read-only category permissions enforced by the server" do
    sign_in(writer)
    public_category.set_permissions(everyone: :readonly)
    public_category.save!
    expect { send_payload }.not_to change { Topic.count }
    expect(response.status).to be_in([403, 422]), response.body
    expect(response.parsed_body["errors"]).to be_present
  end

  it "rejects an anonymous create request" do
    public_category
    expect { send_payload }.not_to change { Topic.count }
    expect(response.status).to eq(403)
  end

  it "returns validation errors without accepting the draft" do
    sign_in(writer)
    public_category
    expect { send_payload(payload(title: "短")) }.not_to change { Topic.count }
    expect(response.status).to eq(422), response.body
    expect(response.parsed_body["errors"]).to be_present
    expect(response.parsed_body["post"]).to be_nil
  end
end
