# Add a descending index to the items table.
# Used with the OAI endpoint queries.

Sequel.migration do
  change do
    add_index :items, :updated, order: :desc, name: 'items_updated_id_desc_index'
    add_index :items, :updated, order: :asc, name: 'items_updated_id_asc_index'
  end
end