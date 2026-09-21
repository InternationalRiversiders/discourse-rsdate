# frozen_string_literal: true
class CreateRsdateRuns < ActiveRecord::Migration[7.2]
  def change
    create_table :river_rsdate_runs do |t|
      t.bigint :user_id, null:false
      t.string :mode, null:false
      t.string :status, null:false, default:'pending'
      t.string :error
      t.jsonb :details, null:false, default:{}
      t.jsonb :result, null:false, default:{}
      t.timestamps
    end
  end
end
