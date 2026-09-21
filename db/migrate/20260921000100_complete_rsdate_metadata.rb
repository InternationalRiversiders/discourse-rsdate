# frozen_string_literal: true
class CompleteRsdateMetadata < ActiveRecord::Migration[7.2]
  def change
    change_column_default :river_rsdate_profiles, :active, from: true, to: false
    add_column :river_rsdate_profiles, :last_published_cycle_key, :string
    add_column :river_rsdate_profiles, :last_published_at, :datetime
    add_column :river_rsdate_profiles, :embedding_updated_at, :datetime
    add_column :river_rsdate_submissions, :submitted_at, :datetime
    add_column :river_rsdate_questionnaires, :created_by_id, :bigint
    add_column :river_rsdate_publications, :unmatched_count, :integer, default: 0, null: false
    add_column :river_rsdate_matches, :published_at, :datetime
    add_column :river_rsdate_matches, :published_by_id, :bigint
    add_index :river_rsdate_matches, [:user_id, :published_at]
    reversible do |dir|
      dir.up do
        execute 'UPDATE river_rsdate_submissions SET submitted_at = updated_at'
        execute 'UPDATE river_rsdate_matches SET published_at = created_at'
        execute 'UPDATE river_rsdate_publications SET unmatched_count = GREATEST(pool_size - pair_count * 2, 0)'
      end
    end
  end
end
