class AddMerchantDetectionModeToFamilies < ActiveRecord::Migration[8.1]
  def change
    add_column :families, :merchant_detection_mode, :string, default: "create_new", null: false

    add_check_constraint :families,
                         "merchant_detection_mode::text = ANY (ARRAY['create_new'::character varying::text, 'existing_only'::character varying::text])",
                         name: "chk_families_merchant_detection_mode"
  end
end
