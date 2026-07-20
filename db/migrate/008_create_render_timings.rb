# frozen_string_literal: true

class CreateRenderTimings < ActiveRecord::Migration[8.0]
  def change
    create_table :render_timings do |t|
      t.references :project, null: false, foreign_key: true
      t.integer :n_shots, null: false
      t.string :resolution, null: false
      t.float :total_seconds, null: false

      t.timestamps
    end
  end
end
