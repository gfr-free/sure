# Sparkline for a sidebar group that is not a single account type: a first
# level formed by another field (owner, institution, ...) or a second level
# (see AccountGrouping). The group is rebuilt from the current user's own
# grouping, so the line sums exactly the accounts the group total next to it
# counts.
class AccountGroupSparklinesController < ApplicationController
  FRAME_ID_FORMAT = /\A[\w-]+\z/

  def show
    @frame_id = turbo_frame_request_id.to_s
    return head(:bad_request) unless @frame_id.match?(FRAME_ID_FORMAT)

    sparkline = AccountGroupSparkline.new(
      account_ids: account_group ? AccountGroupSparkline.counted_account_ids(account_group) : [],
      classification: classification_group.classification
    )

    if sparkline.empty?
      @series = nil
      return render(layout: false)
    end

    # A URL carrying the current version can't go stale, so the browser may reuse it.
    expires_in 1.day if params[:v] == sparkline.version(@frame_id)

    # ETag only: the family sync time misses access changes, so a client
    # sending just If-Modified-Since could keep another account set. The body
    # is addressed to the requesting frame and formatted in the user's locale,
    # so the ETag varies by both.
    if stale?(etag: [ sparkline.cache_key, @frame_id, I18n.locale ])
      @series = sparkline.series
      render layout: false
    end
  end

  private
    def classification_group
      @classification_group ||= begin
        balance_sheet = Current.family.balance_sheet
        params[:classification] == "liability" ? balance_sheet.liabilities : balance_sheet.assets
      end
    end

    # The group or subgroup as the sidebar renders it, or nil when it no
    # longer exists (e.g. the grouping changed since the sidebar rendered).
    def account_group
      @account_group ||= begin
        group = helpers.account_groups_for(classification_group, view: :sidebar)
          .find { |candidate| candidate.key.to_s == params[:group].to_s }

        if group && params[:subgroup].present?
          helpers.account_subgroups(group, view: :sidebar)
            .find { |candidate| candidate.token == params[:subgroup].to_s }
        else
          group
        end
      end
    end
end
