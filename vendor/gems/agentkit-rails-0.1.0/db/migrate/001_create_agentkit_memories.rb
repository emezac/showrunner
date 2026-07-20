# frozen_string_literal: true

class CreateAgentkitMemories < ActiveRecord::Migration[8.0]
  def up
    # Ensure pgvector extension is available
    enable_extension "vector"

    create_table :agentkit_memories do |t|
      t.text      :content,      null: false
      t.column    :embedding,    :vector, limit: 1536   # pgvector — IVFFlat cosine

      t.string    :memory_type,  default: "observation", null: false
      # observation | pattern | insight

      t.string    :status,       default: "raw", null: false
      # raw | embedded | consolidated | archived

      t.string    :source_agent
      t.jsonb     :tags,         default: [], null: false
      t.float     :confidence,   default: 0.7, null: false

      t.references :user,        null: false, foreign_key: true
      t.references :account,     foreign_key: true  # nil if single-tenant

      t.timestamps
    end

    # Cosine similarity index — created after initial data load for performance
    add_index :agentkit_memories, :embedding,
              using:   :ivfflat,
              opclass: :vector_cosine_ops,
              name:    "index_agentkit_memories_on_embedding_ivfflat"

    add_index :agentkit_memories, [:user_id, :status],
              name: "index_agentkit_memories_on_user_id_and_status"

    add_index :agentkit_memories, :memory_type,
              name: "index_agentkit_memories_on_memory_type"

    add_index :agentkit_memories, :confidence,
              name: "index_agentkit_memories_on_confidence"
  end

  def down
    drop_table :agentkit_memories
  end
end
