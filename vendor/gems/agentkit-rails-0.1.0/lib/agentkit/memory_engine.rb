# frozen_string_literal: true

module Agentkit
  # Interface between agents and the agentkit_memories table.
  # Uses pgvector cosine similarity for semantic search.
  #
  # All methods scope to a user (and optionally account for multi-tenant).
  #
  # Usage (from within an ApplicationAgent):
  #   Agentkit::MemoryEngine.store(
  #     content:      "Cliente prefiere reuniones por Zoom",
  #     user:         current_user,
  #     source_agent: self.class.name,
  #     tags:         ["comunicacion", "preferencias"],
  #     memory_type:  "observation",
  #     confidence:   0.85
  #   )
  #
  #   results = Agentkit::MemoryEngine.search(
  #     query:   "preferencias del cliente",
  #     user:    current_user,
  #     k:       5,
  #     threshold: 0.3
  #   )
  class MemoryEngine
    # ─── Write ───────────────────────────────────────────────────────────────

    # Store a new memory and schedule async embedding generation.
    # Returns the created Agentkit::Memory record.
    def self.store(content:, user:, source_agent:, tags: [], memory_type: "observation",
                   confidence: 0.7, account: nil)
      memory = Agentkit::Memory.create!(
        content:      content,
        user:         user,
        source_agent: source_agent,
        tags:         tags,
        memory_type:  memory_type,
        confidence:   confidence,
        account:      account,
        status:       "raw"
      )
      Agentkit::EmbeddingJob.perform_later(memory.id)
      memory
    end

    # ─── Read ─────────────────────────────────────────────────────────────────

    # Semantic search using cosine distance on embedded vectors.
    # Returns AR records ordered by similarity.
    #
    # threshold: maximum cosine *distance* (0 = identical, 1 = orthogonal).
    #            Lower = more similar. Default 0.3 gives good precision.
    def self.search(query:, user:, k: 5, threshold: 0.3, types: nil, account: nil)
      embedding = embed(query)
      return [] unless embedding

      scope = Agentkit::Memory
        .where(user: user, status: %w[embedded consolidated])
        .where("embedding <=> ? < ?", embedding.to_s, threshold)
        .order(Arel.sql("embedding <=> '#{embedding}'"))
        .limit(k)

      scope = scope.where(account: account) if account
      scope = scope.where(memory_type: Array(types)) if types.present?
      scope.to_a
    end

    # ─── Clustering / Consolidation ───────────────────────────────────────────

    # Find raw memories that cluster together (used by DreamingAgent).
    # Returns groups of Memory records whose embeddings are within threshold.
    def self.cluster_raw(user:, threshold: nil, account: nil)
      threshold ||= Agentkit.config.dreaming_threshold
      scope = Agentkit::Memory
        .where(user: user, status: "embedded")
        .order(created_at: :asc)

      scope = scope.where(account: account) if account
      memories = scope.to_a

      # Simple greedy clustering by cosine distance
      clusters = []
      assigned = Set.new

      memories.each_with_index do |mem, i|
        next if assigned.include?(i)

        cluster = [mem]
        assigned << i

        memories[(i + 1)..].each_with_index do |other, j|
          actual_j = j + i + 1
          next if assigned.include?(actual_j)
          next unless mem.embedding && other.embedding

          dist = cosine_distance(mem.embedding, other.embedding)
          if dist < threshold
            cluster << other
            assigned << actual_j
          end
        end

        clusters << cluster if cluster.size > 1
      end

      clusters
    end

    # ─── Private Helpers ──────────────────────────────────────────────────────

    def self.embed(text)
      # Delegates to ruby_llm embedding adapter based on configured model.
      # Returns array of floats or nil on error.
      model = Agentkit.config.embedding_model
      RubyLLM.embed(text, model: model)
    rescue StandardError => e
      Rails.logger.error("[AgentKit::MemoryEngine] Embedding failed: #{e.message}")
      nil
    end
    private_class_method :embed

    def self.cosine_distance(a, b)
      # pgvector stores vectors; in Ruby we compute for clustering.
      a = a.to_a
      b = b.to_a
      dot = a.zip(b).sum { |x, y| x * y }
      norm_a = Math.sqrt(a.sum { |x| x**2 })
      norm_b = Math.sqrt(b.sum { |x| x**2 })
      return 1.0 if norm_a.zero? || norm_b.zero?

      1.0 - (dot / (norm_a * norm_b))
    end
    private_class_method :cosine_distance
  end
end
