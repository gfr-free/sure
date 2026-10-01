class PaperlessConnection < ApplicationRecord
  include Encryptable

  if encryption_ready?
    encrypts :api_token
  end

  belongs_to :family
  belongs_to :user, optional: true
  has_many :paperless_links, dependent: :nullify

  normalizes :base_url, with: ->(url) { url.strip.delete_suffix("/") }

  validates :base_url, :api_token, presence: true
  validate :base_url_must_be_allowed, if: :will_save_change_to_base_url?
  validate :user_must_belong_to_family

  # Document ids are only meaningful on the server they came from, so links made
  # against the old address keep their cached details but stop fetching files.
  after_update :detach_links, if: :saved_change_to_base_url?

  def shared?
    user_id.nil?
  end

  def client
    Provider::Paperless.new(base_url: base_url, api_token: api_token, verify_ssl: verify_ssl)
  end

  # Link into the Paperless web UI. Opening it needs a login in Paperless itself.
  def document_url(document_id)
    "#{base_url}/documents/#{Integer(document_id)}/details"
  end

  # Checks the URL and token against Paperless and records the outcome, so the
  # settings page can show whether the connection works.
  def verify!
    info = client.server_info
    update!(server_version: info[:version], last_connected_at: Time.current, last_error: nil)
    true
  rescue Provider::Paperless::Error => e
    update_columns(last_error: e.message, updated_at: Time.current)
    report_error(e, operation: "verify")
    false
  end

  def report_error(error, operation:)
    DebugLogEntry.capture(
      category: "provider_sync",
      level: "warn",
      message: "Paperless request failed: #{error.message}",
      source: self.class.name,
      provider_key: "paperless",
      family: family,
      user: user,
      metadata: { operation: operation, error_type: error.error_type, paperless_connection_id: id }
    )
  end

  private
    def detach_links
      paperless_links.update_all(paperless_connection_id: nil, updated_at: Time.current)
    end

    def base_url_must_be_allowed
      return if base_url.blank?

      Provider::Paperless::HostGuard.check!(base_url)
    rescue Provider::Paperless::HostGuard::BlockedHost => e
      errors.add(:base_url, e.reason)
    end

    def user_must_belong_to_family
      return if user.nil? || user.family_id == family_id

      errors.add(:user, :invalid)
    end
end
