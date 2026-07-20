# frozen_string_literal: true

class CreateAgentkitAgentSuggestions < ActiveRecord::Migration[8.0]
  def change
    create_table :agentkit_agent_suggestions do |t|
      t.string    :suggestion_type, null: false
      # scope_creep | risk | communication | contract | case_strategy | etc.

      t.string    :title,           null: false
      t.text      :description

      t.string    :status,          default: "pending", null: false
      # pending | accepted | rejected | snoozed | silenced | auto_applied

      t.string    :priority,        default: "medium", null: false
      # low | medium | high | critical

      t.jsonb     :payload,         default: {}, null: false
      t.string    :source_agent,    null: false

      # Polymorphic association to the domain object this suggestion refers to
      t.references :suggestable,    polymorphic: true
      t.references :user,           null: false, foreign_key: true

      t.datetime  :resolved_at

      t.timestamps
    end

    add_index :agentkit_agent_suggestions, [:user_id, :status],
              name: "index_agentkit_suggestions_on_user_id_and_status"

    add_index :agentkit_agent_suggestions, [:suggestable_type, :suggestable_id],
              name: "index_agentkit_suggestions_on_suggestable"

    add_index :agentkit_agent_suggestions, :priority,
              name: "index_agentkit_suggestions_on_priority"
  end
end
