module Family::PaperlessConnectable
  extend ActiveSupport::Concern

  # per_user: every member connects their own Paperless account, so Paperless
  # permissions apply per person. family: an admin sets up one connection that
  # every member uses.
  PAPERLESS_CONNECTION_MODES = %w[per_user family].freeze

  included do
    has_many :paperless_connections, dependent: :destroy
    has_many :paperless_links, dependent: :destroy

    validates :paperless_connection_mode, inclusion: { in: PAPERLESS_CONNECTION_MODES }
  end

  def paperless_shared_connection?
    paperless_connection_mode == "family"
  end

  # The connection the user searches and links with. Viewing an existing link
  # uses the link's own connection instead (see PaperlessLink#file).
  def paperless_connection_for(user)
    return if user.nil?

    if paperless_shared_connection?
      paperless_connections.find_by(user_id: nil)
    else
      paperless_connections.find_by(user_id: user.id)
    end
  end

  def can_manage_paperless_connection?(user)
    return false if user.nil?

    paperless_shared_connection? ? user.admin? : true
  end
end
