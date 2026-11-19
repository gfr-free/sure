# Categories, family merchants and tags belong to a family, but the
# transactions that use them belong to an account. When accounts
# move to another family (User#transfer_to_family!), their entries would keep
# pointing at records the new family cannot see. This repoints each reference
# at the new family's record of the same name, copying the record there when
# the new family has none. The old family keeps its own records untouched.
class User::FamilyReferenceRemapper
  def initialize(accounts, new_family)
    @account_ids = accounts.map(&:id)
    @new_family = new_family
  end

  def remap!
    return if account_ids.empty?

    remap_categories!
    remap_merchants!
    remap_tags!
  end

  private
    attr_reader :account_ids, :new_family

    def transactions
      Transaction.where(id: Entry.where(account_id: account_ids, entryable_type: "Transaction").select(:entryable_id))
    end

    def remap_categories!
      foreign_categories = Category
        .where(id: transactions.select(:category_id))
        .where.not(family_id: new_family.id)
        .includes(:parent)

      foreign_categories.each do |category|
        target = category_in_new_family(category)
        repoint!(:category_id, category, target)
      end
    end

    def category_in_new_family(category)
      find_or_create_by_name(new_family.categories, category.name) do
        parent = category.parent && category_in_new_family(category.parent)

        new_family.categories.create!(
          name: category.name,
          color: category.color,
          lucide_icon: category.lucide_icon,
          # A same-named match in the new family can itself be a subcategory;
          # nesting under it would exceed the two-level limit.
          parent: parent&.parent_id.nil? ? parent : nil
        )
      end
    end

    def remap_merchants!
      foreign_merchants = FamilyMerchant
        .where(id: transactions.select(:merchant_id))
        .where.not(family_id: new_family.id)

      foreign_merchants.each do |merchant|
        target, created = FamilyMerchant.find_or_create_with_name(
          new_family,
          merchant.name,
          color: merchant.color,
          website_url: merchant.website_url
        )
        target.logo.attach(merchant.logo.blob) if created && merchant.logo.attached?

        repoint!(:merchant_id, merchant, target)
      end
    end

    def remap_tags!
      taggings = Tagging.where(taggable_type: "Transaction", taggable_id: transactions.select(:id))
      foreign_tags = Tag.where(id: taggings.select(:tag_id)).where.not(family_id: new_family.id)

      foreign_tags.each do |tag|
        target = find_or_create_by_name(new_family.tags, tag.name) do
          new_family.tags.create!(name: tag.name, color: tag.color)
        end

        # A transaction that already carries the target tag keeps just one tagging.
        taggings.where(tag_id: tag.id, taggable_id: taggings.where(tag_id: target.id).select(:taggable_id)).delete_all
        taggings.where(tag_id: tag.id).update_all(tag_id: target.id, updated_at: Time.current)
      end
    end

    # Enrichments record the value an automatic source set, and
    # Transaction.enriched_from_sql only counts a claim whose value still equals
    # the column. They move along so a remap is not mistaken for a user edit.
    def repoint!(attribute, from, to)
      transactions.where(attribute => from.id).update_all(attribute => to.id, updated_at: Time.current)
      DataEnrichment
        .where(enrichable_type: "Transaction", enrichable_id: transactions.select(:id), attribute_name: attribute.to_s, value: from.id)
        .update_all(value: to.id, updated_at: Time.current)
    end

    # The savepoint lets a concurrent insert of the same name lose on the
    # unique index without aborting the surrounding transfer transaction.
    def find_or_create_by_name(scope, name)
      scope.find_by(name: name) || begin
        scope.transaction(requires_new: true) { yield }
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
        raise if e.is_a?(ActiveRecord::RecordInvalid) && !e.record.errors.of_kind?(:name, :taken)
        scope.find_by!(name: name)
      end
    end
end
