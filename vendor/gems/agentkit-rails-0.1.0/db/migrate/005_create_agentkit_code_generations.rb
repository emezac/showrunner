# frozen_string_literal: true

class CreateAgentkitCodeGenerations < ActiveRecord::Migration[8.0]
  def change
    create_table :agentkit_code_generations do |t|
      t.references :evolution_item,
                   null:        false,
                   foreign_key: { to_table: :agentkit_evolution_items }

      t.string    :target_file,    null: false  # relative path from Rails.root
      t.text      :generated_code
      t.text      :explanation

      t.string    :status, default: "draft", null: false
      # draft | reviewed | applied | failed

      t.datetime  :applied_at

      t.references :user, null: false, foreign_key: true

      t.timestamps
    end

    add_index :agentkit_code_generations, [:evolution_item_id, :status],
              name: "index_agentkit_code_gens_on_evolution_item_and_status"
  end
end
