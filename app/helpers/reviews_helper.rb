module ReviewsHelper
  REVIEW_KIND_ICONS = {
    "uncategorized" => "tag",
    "no_merchant" => "store",
    "flagged" => "flag",
    "long_pending" => "clock",
    "possible_duplicate" => "copy",
    "transfer_suggestion" => "link-2"
  }.freeze

  def review_kind_icon(kind)
    REVIEW_KIND_ICONS.fetch(kind)
  end
end
