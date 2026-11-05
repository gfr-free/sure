# Sparkline for a sidebar group that is not a single account type: a first
# level formed by another field (owner, institution, ...) or a second level
# (see AccountGrouping). The group is rebuilt from the current user's own
# grouping, so the line sums exactly the accounts the group total next to it
# counts.
class AccountGroupSparklinesController < ApplicationController
  include AccountSetSparkline

  FRAME_ID_FORMAT = /\A[\w-]+\z/

  def show
    @frame_id = turbo_frame_request_id.to_s
    return head(:bad_request) unless @frame_id.match?(FRAME_ID_FORMAT)

    if sparkline_account_ids.empty?
      @series = nil
      return render(layout: false)
    end

    render_account_set_sparkline
  end

  private
    def classification_group
      balance_sheet = Current.family.balance_sheet
      params[:classification] == "liability" ? balance_sheet.liabilities : balance_sheet.assets
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

    def counted_account_ids
      return [] unless account_group

      BalanceSheet::ClassificationGroup.counted_accounts(account_group.accounts).map(&:id)
    end

    # The group's counted accounts, narrowed again by the same rules the type
    # sparkline uses, so both read their rows the same way.
    def account_scope
      Current.accessible_accounts
        .visible
        .included_in_reports
        .included_in_finances_for(Current.user)
        .where(id: counted_account_ids)
    end

    def sparkline_favorable_direction
      params[:classification] == "liability" ? "down" : "up"
    end

    def sparkline_cache_name
      "account_group_sparkline"
    end

    # The body is addressed to the requesting frame, and desktop, mobile and
    # each tab load the same URL into frames with different ids.
    def sparkline_response_variant
      @frame_id
    end
end
