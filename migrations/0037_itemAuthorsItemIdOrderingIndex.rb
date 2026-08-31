# Adds a unique index to the item_authors table on item_id + ordering
# Used with the OAI endpoint queries.

Sequel.migration do
  change do
    alter_table(:item_authors) do
      add_index [:item_id, :ordering], :unique => true, name: 'item_authors_item_id_ordering_index'
    end
  end
end