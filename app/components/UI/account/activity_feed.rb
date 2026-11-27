class UI::Account::ActivityFeed < ApplicationComponent
  attr_reader :feed_data, :pagy, :q, :has_unread

  def initialize(feed_data:, pagy:, q: {}, has_unread: false)
    @feed_data = feed_data
    @pagy = pagy
    @q = q || {}
    @has_unread = has_unread
  end

  def id
    dom_id(account, :activity_feed)
  end

  def broadcast_channel
    account
  end

  def broadcast_refresh!
    Turbo::StreamsChannel.broadcast_replace_to(
      broadcast_channel,
      target: id,
      renderable: self,
      layout: false
    )
  end

  def activity_dates
    feed_data.entries_by_date
  end

  # Hidden copies of the active filters while the Filter menu is not loaded,
  # so a search typed before opening it keeps them. The loaded menu replaces
  # them with its own inputs.
  def active_filter_fields
    q.to_h.except("search").flat_map do |key, value|
      if value.is_a?(Array)
        value.map { |item| [ "q[#{key}][]", item ] }
      else
        [ [ "q[#{key}]", value ] ]
      end
    end
  end

  private
    def account
      feed_data.account
    end
end
