# frozen_string_literal: true

class CreateAgentkitAgentLogs < ActiveRecord::Migration[8.0]
  def change
    create_table :agentkit_agent_logs do |t|
      t.string    :agent_name,     null: false
      t.string    :event_type
      # started | completed | failed | memorized | suggested | recalled

      t.text      :prompt_preview  # first 500 chars of prompt (not full)
      t.integer   :tokens_used
      t.float     :cost_usd
      t.integer   :duration_ms
      t.string    :status
      t.jsonb     :payload,        default: {}, null: false

      t.references :user, foreign_key: true  # nullable — system jobs have no user

      t.timestamps
    end

    add_index :agentkit_agent_logs, [:agent_name, :created_at],
              name: "index_agentkit_agent_logs_on_agent_name_and_created_at"

    add_index :agentkit_agent_logs, :event_type,
              name: "index_agentkit_agent_logs_on_event_type"

    add_index :agentkit_agent_logs, :status,
              name: "index_agentkit_agent_logs_on_status"
  end
end
