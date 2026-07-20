# frozen_string_literal: true

class CreateProjects < ActiveRecord::Migration[8.0]
  def change
    create_table :projects do |t|
      t.text :prompt, null: false
      t.string :title
      t.integer :seed
      t.string :status, default: "queued", null: false
      t.integer :token_budget, default: 18000, null: false
      t.integer :tokens_used, default: 0, null: false
      t.integer :tokens_remaining
      t.integer :video_credits_used, default: 0, null: false
      t.string :resolution, default: "720P", null: false
      t.integer :duration, default: 75, null: false
      t.jsonb :manifest, default: {}
      t.string :final_video_url
      t.jsonb :direction, default: {}
      t.jsonb :genes_override, default: []
      t.references :user, null: false, foreign_key: true

      t.timestamps
    end

    add_index :projects, :status
  end
end
