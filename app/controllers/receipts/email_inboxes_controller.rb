# The current user's own address for sending receipts by e-mail.
class Receipts::EmailInboxesController < ApplicationController
  before_action :require_preview_features!
  before_action :ensure_available!

  # Switches the address on, or replaces it so the old one stops working.
  def create
    rotated = Current.user.receipt_inbox_token.present?
    Receipt::EmailInbox.enable!(Current.user)
    redirect_to receipts_path, notice: t(rotated ? ".rotated" : ".enabled")
  end

  def update
    Receipt::EmailInbox.update_senders!(Current.user, params.dig(:email_inbox, :senders))
    redirect_to receipts_path, notice: t(".updated")
  rescue ActiveRecord::RecordInvalid
    redirect_to receipts_path, alert: t(".invalid", count: Receipt::EmailInbox::MAX_EXTRA_SENDERS)
  end

  def destroy
    Receipt::EmailInbox.disable!(Current.user)
    redirect_to receipts_path, notice: t(".disabled")
  end

  private
    def ensure_available!
      return if Receipt.manager?(Current.user) && Receipt::EmailInbox.configured?

      redirect_to receipts_path, alert: t("accounts.not_authorized")
    end
end
