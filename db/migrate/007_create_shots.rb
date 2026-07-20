# frozen_string_literal: true

class CreateShots < ActiveRecord::Migration[8.0]
  def change
    create_table :shots do |t|
      t.references :project, null: false, foreign_key: true
      t.string :shot_id, null: false
      t.text :visual_prompt
      t.boolean :locked, default: false, null: false
      t.bigint :variant_of_id
      t.integer :duration, default: 5, null: false

      t.timestamps
    end

    add_index :shots, [:project_id, :shot_id], unique: true
    add_index :shots, :variant_of_id
  end
end
