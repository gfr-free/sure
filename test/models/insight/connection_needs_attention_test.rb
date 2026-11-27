require "test_helper"

# Who sees and who is notified about a connection problem: an insight naming
# several accounts (metadata account_ids) instead of one.
class Insight::ConnectionNeedsAttentionTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @admin = users(:family_admin)
    @member = users(:family_member)
    [ @admin, @member ].each { |user| user.update!(preferences: user.preferences.merge("preview_features_enabled" => true)) }
  end

  test "the feed shows a connection whose accounts every member can open" do
    insight = connection_insight(accounts(:depository), accounts(:credit_card))

    assert_includes @family.insights.visible, insight
  end

  test "the feed hides a connection with an account private to one member" do
    insight = connection_insight(accounts(:depository), accounts(:connected))

    assert_not_includes @family.insights.visible, insight
  end

  test "the feed hides a connection whose account was deleted" do
    insight = connection_insight(accounts(:depository), Struct.new(:id).new(SecureRandom.uuid))

    assert_not_includes @family.insights.visible, insight
  end

  test "a malformed account list hides the insight instead of raising" do
    insight = connection_insight(accounts(:depository))
    insight.update_columns(metadata: insight.metadata.merge("account_ids" => "not-a-list"))

    assert_not_includes @family.insights.visible, insight
  end

  test "admins and members who can open a linked account are notified" do
    insight = connection_insight(accounts(:depository))

    assert insight.notifies?(@admin)
    assert insight.notifies?(@member)
  end

  test "a member who cannot open any linked account is not notified" do
    insight = connection_insight(accounts(:connected))

    assert insight.notifies?(@admin), "an admin can reconnect it"
    assert_not insight.notifies?(@member)
  end

  test "the native app is only notified about a connection the shared feed shows" do
    hidden = connection_insight(accounts(:connected))
    shown = connection_insight(accounts(:depository))

    assert hidden.notifies?(@admin, channel: "WebPushSubscription")
    assert_not hidden.notifies?(@admin, channel: "PushSubscription"), "the app could not open it"
    assert shown.notifies?(@admin, channel: "PushSubscription")
  end

  test "notification still needs preview features" do
    @member.update!(preferences: @member.preferences.merge("preview_features_enabled" => false))
    insight = connection_insight(accounts(:depository))

    assert_not insight.notifies?(@member)
  end

  test "a push opens the first linked account the recipient can see" do
    insight = connection_insight(accounts(:depository), accounts(:connected))

    assert_equal "/accounts/#{accounts(:depository).id}", insight.notification_path_for(@member)
  end

  test "an admin who can see none of the accounts is sent to where connections are repaired" do
    other = accounts(:connected)
    other.update!(owner: @member)
    AccountShare.where(account: other).delete_all
    insight = connection_insight(other, connection_type: "TradeRepublicItem")

    assert_equal "/settings/providers", insight.notification_path_for(@admin)

    insight.update!(metadata: insight.metadata.merge("connection_type" => "PlaidItem"))
    assert_equal "/accounts", insight.notification_path_for(@admin)
  end

  test "other insights still open the feed" do
    insight = insights(:spending_anomaly_dining)

    assert_equal "/insights#insight_#{insight.id}", insight.notification_path_for(@admin)
  end

  private
    def connection_insight(*accounts, connection_type: "TradeRepublicItem")
      @family.insights.create!(
        insight_type: "connection_needs_attention", priority: "high", status: "active",
        title: "Your connection to Test Bank needs to be renewed", body: "body",
        metadata: { "connection_type" => connection_type, "connection_id" => SecureRandom.uuid, "reason" => "reconnect",
                    "account_ids" => accounts.map(&:id) },
        dedup_key: "connection_needs_attention:#{SecureRandom.uuid}", generated_at: Time.current
      )
    end
end
