# Add a descending index to the items table.
# Used with the OAI endpoint queries.

Sequel.migration do
  change do
    add_index :items, :updated, order: :desc
  end
end