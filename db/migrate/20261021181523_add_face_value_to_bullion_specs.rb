class AddFaceValueToBullionSpecs < ActiveRecord::Migration[8.1]
  def change
    # The nominal value of a custom coin that is legal tender. Catalogue coins
    # take theirs from config/bullion_products.yml.
    add_column :bullion_specs, :face_value, :decimal, precision: 19, scale: 4
    add_column :bullion_specs, :face_value_currency, :string

    add_check_constraint :bullion_specs, "face_value IS NULL OR face_value > 0", name: "chk_bullion_specs_face_value_positive"
    add_check_constraint :bullion_specs, "(face_value IS NULL) = (face_value_currency IS NULL)",
                         name: "chk_bullion_specs_face_value_currency"
  end
end
