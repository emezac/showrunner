# frozen_string_literal: true

class CreateAgentkitEvolutionItems < ActiveRecord::Migration[8.0]
  def change
    create_table :agentkit_evolution_items do |t|
      t.string    :item_type
      # new_field | new_agent | new_dsl | refactor | new_skill

      t.string    :title,       null: false
      t.text      :description
      t.text      :rationale

      t.string    :status,      default: "pending", null: false
      # pending | accepted | in_progress | done | rejected

      t.string    :priority
      # low | medium | high | critical

      t.references :user, null: false, foreign_key: true

      t.timestamps
    end

    add_index :agentkit_evolution_items, [:user_id, :status],
              name: "index_agentkit_evolution_items_on_user_id_and_status"

    add_index :agentkit_evolution_items, :item_type,
              name: "index_agentkit_evolution_items_on_item_type"
  end
end
