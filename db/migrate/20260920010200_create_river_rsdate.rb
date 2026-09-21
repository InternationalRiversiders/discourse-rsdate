# frozen_string_literal: true
class CreateRiverRsdate < ActiveRecord::Migration[7.2]
  def change
    create_table :river_rsdate_commands do |t|
      t.bigint :user_id, null: false
      t.string :key, null: false
      t.string :fingerprint, null: false
      t.jsonb :result, null: false, default: {}
      t.timestamps
    end
    add_index :river_rsdate_commands, [:user_id, :key], unique: true
    create_table :river_rsdate_events do |t|
      t.bigint :user_id, null: false
      t.string :key, null: false
      t.string :text, null: false
      t.string :path, null: false
      t.bigint :notification_id
      t.timestamps
    end
    add_index :river_rsdate_events, :key, unique: true
    create_table :river_rsdate_audits do |t|
      t.bigint :user_id, null: false
      t.string :action, null: false
      t.string :target_kind
      t.bigint :target_id
      t.string :reason, null: false
      t.jsonb :details, null: false, default: {}
      t.timestamps
    end
    create_table :river_rsdate_legacies do |t|
      t.string :source, null: false
      t.string :legacy_id, null: false
      t.string :target_kind
      t.bigint :target_id
      t.jsonb :data, null: false, default: {}
      t.timestamps
    end
    add_index :river_rsdate_legacies, [:source, :legacy_id], unique: true
    create_table :river_rsdate_media do |t|
      t.bigint :user_id, null: false
      t.string :token, null: false
      t.binary :bytes, null: false
      t.integer :size, null: false
      t.timestamps
    end
    add_index :river_rsdate_media, :token, unique: true
    create_table :river_rsdate_reactions do |t|
      t.bigint :user_id, null: false
      t.string :target_kind, null: false
      t.bigint :target_id, null: false
      t.integer :value, null: false
      t.timestamps
    end
    add_index :river_rsdate_reactions, [:user_id, :target_kind, :target_id], unique: true, name: 'river_rsdate_reaction_unique'
    add_check_constraint :river_rsdate_reactions, 'value IN (-1,1)', name: 'river_rsdate_reaction_value'
    create_table :river_rsdate_reports do |t|
      t.bigint :user_id, null: false
      t.string :target_kind, null: false
      t.bigint :target_id, null: false
      t.string :reason, null: false
      t.datetime :handled_at
      t.timestamps
    end
    add_index :river_rsdate_reports, [:user_id, :target_kind, :target_id], unique: true, name: 'river_rsdate_report_unique'
    create_table :river_rsdate_comments do |t|
      t.bigint :user_id, null: false
      t.string :target_kind, null: false
      t.bigint :target_id, null: false
      t.bigint :parent_id
      t.text :body, null: false
      t.boolean :anonymous, null: false, default: false
      t.string :status, null: false, default: 'visible'
      t.decimal :rating, precision: 3, scale: 1
      t.jsonb :media_ids, null: false, default: []
      t.timestamps
    end
    add_index :river_rsdate_comments, [:target_kind, :target_id, :id], name: 'river_rsdate_comment_target'
    add_foreign_key :river_rsdate_comments, :river_rsdate_comments, column: :parent_id
    add_check_constraint :river_rsdate_comments, 'rating IS NULL OR (rating >= 0.5 AND rating <= 5)', name: 'river_rsdate_comment_rating'
    create_table :river_rsdate_profiles do |t|
      t.bigint :user_id, null:false
      t.string :nickname, null:false
      t.string :gender, null:false
      t.string :target_gender, null:false
      t.string :school, null:false
      t.string :campus, null:false
      t.string :grade, null:false
      t.string :mbti
      t.string :zodiac
      t.text :interests
      t.text :schedule
      t.text :bio
      t.boolean :active, null:false, default:true
      t.jsonb :embedding
      t.string :embedding_model
      t.string :embedding_fingerprint
      t.timestamps
    end
    add_index :river_rsdate_profiles, :user_id, unique:true
    create_table :river_rsdate_questionnaires do |t|
      t.string :title, null:false
      t.text :description
      t.boolean :required, null:false, default:true
      t.boolean :active, null:false, default:true
      t.integer :revision, null:false, default:1
      t.integer :position, null:false, default:0
      t.jsonb :questions, null:false, default:[]
      t.timestamps
    end
    create_table :river_rsdate_submissions do |t|
      t.bigint :user_id, null:false
      t.bigint :questionnaire_id, null:false
      t.integer :revision, null:false
      t.jsonb :answers, null:false, default:{}
      t.timestamps
    end
    add_index :river_rsdate_submissions, [:user_id,:questionnaire_id], unique:true
    add_foreign_key :river_rsdate_submissions, :river_rsdate_questionnaires, column: :questionnaire_id
    create_table :river_rsdate_publications do |t|
      t.string :cycle_key, null:false
      t.bigint :user_id
      t.string :mode, null:false
      t.integer :pool_size, null:false
      t.integer :pair_count, null:false
      t.timestamps
    end
    add_index :river_rsdate_publications, :cycle_key, unique:true
    create_table :river_rsdate_matches do |t|
      t.bigint :publication_id, null:false
      t.bigint :user_id, null:false
      t.bigint :partner_id, null:false
      t.jsonb :details, null:false, default:{}
      t.boolean :current, null:false, default:true
      t.timestamps
    end
    add_index :river_rsdate_matches, [:publication_id,:user_id], unique:true
    add_index :river_rsdate_matches, :user_id, unique:true, where:'current = true', name:'river_rsdate_current_unique'
    add_foreign_key :river_rsdate_matches, :river_rsdate_publications, column: :publication_id
  end
end
