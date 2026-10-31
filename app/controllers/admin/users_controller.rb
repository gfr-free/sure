# frozen_string_literal: true

module Admin
  class UsersController < Admin::BaseController
    PER_PAGE = 25

    before_action :set_user, only: %i[show update deletion destroy]

    def index
      authorize User
      scope = policy_scope(User)
        .left_joins(family: :subscription)
        .preload(:oidc_identities, family: :subscription)
        .with_attached_profile_image

      scope = scope.where(role: params[:role]) if params[:role].present?
      scope = apply_trial_filter(scope) if params[:trial_status].present?
      scope = scope.admin_search(params[:q]) if params[:q].present?

      @pagy, users = pagy(scope.ordered_by_family_activity, limit: PER_PAGE, page: safe_page)

      family_ids = users.map(&:family_id).uniq
      @accounts_count_by_family = Account.where(family_id: family_ids).group(:family_id).count
      @entries_count_by_family = users.to_h { |user| [ user.family_id, user.family_entries_count ] }
      # Counted over the filtered scope, not the page, so a family split by a
      # page break still shows its full number of matching members.
      @members_count_by_family = scope.where(family_id: family_ids).group(:family_id).count

      @families_with_users = users.group_by(&:family)

      @invitations_by_family = Invitation.pending
        .where(family_id: family_ids)
        .group_by(&:family_id)

      @families = Family.order(:name, :created_at)
      @unused_families = Family.left_joins(:users).where(users: { id: nil }).order(:name, :created_at)

      @sso_identity_blocks = SsoIdentityBlock.order(created_at: :desc)

      # Used by the view to hide the "remove" action for the sole remaining
      # active super admin, computed once here instead of per-row.
      @active_super_admin_count = User.where(role: :super_admin, active: true).count
      @super_admin_count = User.where(role: :super_admin).count
    end

    # Counters only: an operator sees how much a user's family stores and
    # whether its syncs fail, never balances, account names, entries or raw
    # sync error text (it can echo imported row values).
    def show
      authorize @user

      family = @user.family
      family_syncs = Sync.for_family(family)

      @members_count = family.users.count
      @accounts_count = family.accounts.count
      @entries_count = family.entries.count
      @syncs_count, @failed_syncs_count, @last_completed_sync_at = family_syncs.pick(
        Arel.sql("COUNT(*)"),
        Arel.sql("COUNT(*) FILTER (WHERE syncs.status = 'failed')"),
        Arel.sql("MAX(syncs.completed_at)")
      )
      @recent_failed_syncs = family_syncs.failed.ordered.limit(5).to_a
    end

    def update
      authorize @user

      if demoting_last_super_admin?
        redirect_back_or_to admin_users_path, alert: t(".last_super_admin_error")
        return
      end

      if membership_change_requested? && password_change_requested?
        redirect_back_or_to admin_users_path, alert: t(".password_and_family_conflict")
        return
      end

      if password_change_requested? && !password_change_allowed_for?(@user)
        redirect_back_or_to admin_users_path, alert: t(".password_disabled")
        return
      end

      if password_change_requested?
        errors = validate_password_criteria(user_params[:password])
        if errors.any?
          redirect_back_or_to admin_users_path, alert: errors.join(" ")
          return
        end
      end

      if membership_change_requested?
        target_family = nil

        ActiveRecord::Base.transaction do
          target_family = target_family_for_update

          if target_family.nil?
            raise ActiveRecord::Rollback
          end

          @user.transfer_to_family!(target_family, role: user_params[:role])
        end

        if target_family.nil?
          redirect_back_or_to admin_users_path, alert: t(".family_required")
          return
        end

        Rails.logger.info(
          "[Admin::Users] Family changed - " \
          "by_user_id=#{Current.user.id} " \
          "target_user_id=#{@user.id} " \
          "new_family_id=#{@user.family_id} " \
          "new_role=#{@user.role}"
        )

        redirect_back_or_to admin_users_path, notice: t(".success_family")
      elsif @user.update(user_update_attributes)
        changes = []
        changes << :role if @user.saved_change_to_role?
        changes << :password if @user.saved_change_to_password_digest?

        success_key = case changes
        when [ :role, :password ] then ".success_role_and_password"
        when [ :password ]        then ".success_password"
        else                           ".success_role"
        end

        Rails.logger.info(
          "[Admin::Users] User details changed (#{changes.join(', ')}) - " \
          "by_user_id=#{Current.user.id} " \
          "target_user_id=#{@user.id} " \
          "new_role=#{@user.role}"
        )

        redirect_back_or_to admin_users_path, notice: t(success_key)
      else
        redirect_back_or_to admin_users_path, alert: @user.errors.full_messages.to_sentence.presence || t(".failure")
      end
    rescue ActiveRecord::RecordInvalid => e
      redirect_back_or_to admin_users_path, alert: e.record.errors.full_messages.to_sentence
    rescue ActiveRecord::RecordNotFound
      redirect_back_or_to admin_users_path, alert: t(".failure")
    end



    def deletion
      # Same self-removal short-circuit as #destroy. UserPolicy#destroy? already
      # denies it, but Pundit::NotAuthorizedError is not rescued anywhere in this
      # app, so opening the confirmation modal for yourself (the index view hides
      # the button, but the URL is guessable) would 500 instead of redirecting.
      if @user.id == Current.user.id
        redirect_back_or_to admin_users_path, alert: t("admin.users.destroy.cannot_remove_self")
        return
      end

      authorize @user, :destroy?
      render layout: false
    end

    def destroy
      # Self-removal is also denied by UserPolicy#destroy?, but checking it here
      # first turns it into a friendly redirect instead of an unhandled
      # Pundit::NotAuthorizedError (there is no rescue_from for it in this app).
      if @user.id == Current.user.id
        redirect_back_or_to admin_users_path, alert: t(".cannot_remove_self")
        return
      end

      authorize @user

      unless ActiveSupport::SecurityUtils.secure_compare(params[:confirmation_email].to_s, @user.email)
        redirect_back_or_to admin_users_path, alert: t(".confirmation_mismatch")
        return
      end

      removed = @user.transaction do
        next false unless @user.permanently_remove!

        SsoAuditLog.log_user_removed!(user: @user, actor: Current.user, request: request)
        true
      end

      if removed
        redirect_back_or_to admin_users_path, notice: t(".success")
      else
        redirect_back_or_to admin_users_path, alert: @user.errors.full_messages.to_sentence.presence || t(".failure")
      end
    end

    private

      helper_method :family_label_for, :password_change_allowed_for?, :list_params

      # Search, filter and page of the user list, carried to the detail page
      # and back so the admin returns to the same slice of the list.
      def list_params
        request.query_parameters.slice("q", "page", "role", "trial_status").compact_blank
      end

      def set_user
        @user = User.find(params[:id])
      end

      def user_params
        params.require(:user).permit(:role, :family_id, :new_family_name, :new_family_moniker, :password)
      end

      def user_update_attributes
        attrs = {}
        attrs[:role] = user_params[:role] if user_params[:role].present?
        if user_params[:password].present? && @user.has_local_password?
          attrs[:password] = user_params[:password]
        end
        attrs
      end

      def password_change_requested?
        user_params[:password].present? && @user.has_local_password?
      end

      # Same policy as PasswordsController and local sign-in: a password that
      # could not be used to sign in must not be set by an admin either.
      def password_change_allowed_for?(user)
        user.has_local_password? && AuthConfig.local_login_allowed_for?(user)
      end

      def validate_password_criteria(password)
        errors = []
        errors << t(".password_too_short") if password.length < 8
        errors << t(".password_missing_case") unless password.match?(/[A-Z]/) && password.match?(/[a-z]/)
        errors << t(".password_missing_number") unless password.match?(/\d/)
        errors << t(".password_missing_special") unless password.match?(/[!@#$%^&*(),.?":{}|<>]/)
        errors
      end

      def membership_change_requested?
        return true if user_params[:new_family_name].to_s.strip.present?
        return true if user_params[:family_id] == "new"

        user_params[:family_id].present? && user_params[:family_id] != @user.family_id.to_s
      end

      def target_family_for_update
        new_family_name = user_params[:new_family_name].to_s.strip

        if new_family_name.present?
          Family.create!(
            name: new_family_name,
            moniker: user_params[:new_family_moniker].presence || "Family"
          )
        elsif user_params[:family_id].present? && user_params[:family_id] != "new"
          Family.find(user_params[:family_id])
        end
      end

      def family_label_for(family)
        return "" if family.nil?

        family.name.presence || "#{family.moniker_label} (#{family.id.to_s.first(8)})"
      end

      def demoting_last_super_admin?
        user_params[:role].present? &&
          @user.super_admin? &&
          user_params[:role] != "super_admin" &&
          User.where(role: :super_admin).where.not(id: @user.id).none?
      end

      # Pagy raises on a page below 1; the overflow setting only covers pages past the end.
      def safe_page
        [ params[:page].to_s.to_i, 1 ].max
      end

      def apply_trial_filter(scope)
        case params[:trial_status]
        when "expiring_soon"
          scope.where(subscriptions: { status: :trialing })
            .where(subscriptions: { trial_ends_at: Time.current..7.days.from_now })
        when "trialing"
          scope.where(subscriptions: { status: :trialing })
        else
          scope
        end
      end
  end
end
