class PaperlessLink < ApplicationRecord
  LINKABLE_TYPES = %w[Transaction].freeze

  # Content types a browser may render inline from the proxy. Everything else is
  # sent as a download so Paperless content can never run as a page on Sure's origin.
  INLINE_CONTENT_TYPES = %w[application/pdf image/png image/jpeg image/gif image/webp].freeze

  belongs_to :family
  belongs_to :linkable, polymorphic: true
  belongs_to :paperless_connection, optional: true
  belongs_to :created_by, class_name: "User", optional: true

  validates :linkable_type, inclusion: { in: LINKABLE_TYPES }
  validates :document_id, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :document_id, uniqueness: { scope: %i[linkable_type linkable_id] }
  validate :linkable_must_belong_to_family

  scope :recent_first, -> { order(created_at: :desc) }

  # Links a Paperless document to a record and caches its title, date and
  # correspondent from Paperless.
  def self.link!(linkable:, connection:, document_id:, user:)
    fetched_from = connection.base_url
    document = connection.client.document(document_id)

    # Changing the address detaches links in the same transaction that locks the
    # connection row, so holding that lock keeps a link from landing on a server
    # its document id did not come from.
    transaction do
      connection.lock!
      raise Provider::Paperless::Error.new("Paperless address changed, please search again", :connection_changed) if connection.base_url != fetched_from

      create!(
        family: connection.family,
        linkable: linkable,
        paperless_connection: connection,
        created_by: user,
        document_id: document[:id],
        title: document[:title],
        document_created_on: document[:created_on],
        correspondent_name: document[:correspondent_name],
        mime_type: document[:mime_type]
      )
    end
  end

  # Fetches a file (thumb, preview or download) through the connection that
  # created the link, so members without their own connection can view it too.
  def file(kind)
    raise Provider::Paperless::Error.new("Paperless connection was removed", :not_connected) if paperless_connection.nil?

    paperless_connection.client.file(document_id, kind: kind)
  end

  def document_url
    paperless_connection&.document_url(document_id)
  end

  def image?
    mime_type.to_s.start_with?("image/")
  end

  def visible_to?(user)
    case linkable
    when Transaction
      family.transactions.joins(entry: :account).merge(Account.accessible_by(user)).exists?(id: linkable_id)
    else
      false
    end
  end

  private
    def linkable_must_belong_to_family
      return if linkable.nil? || family_id.nil?

      linkable_family_id = linkable.respond_to?(:entry) ? linkable.entry&.account&.family_id : nil
      errors.add(:linkable, :invalid) unless linkable_family_id == family_id
    end
end
