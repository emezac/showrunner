# frozen_string_literal: true

module Agentkit
  # Generates and stores a vector embedding for a single Memory record.
  # Dispatched by MemoryEngine.store — should not be called directly.
  #
  # On success: updates memory.status from "raw" → "embedded"
  # On failure: retries up to 3 times with exponential backoff, then logs error.
  class EmbeddingJob < ApplicationJob
    queue_as :agentkit_embeddings

    retry_on StandardError, wait: :polynomially_longer, attempts: 3

    def perform(memory_id)
      memory = Agentkit::Memory.find_by(id: memory_id)
      return unless memory # Silently skip if deleted

      embedding = generate_embedding(memory.content)
      return unless embedding

      memory.update!(
        embedding: embedding,
        status:    "embedded"
      )

      Rails.logger.debug("[AgentKit::EmbeddingJob] Memory #{memory_id} embedded (#{embedding.size}d).")
    end

    private

    def generate_embedding(text)
      model = Agentkit.config.embedding_model
      RubyLLM.embed(text, model: model)
    rescue StandardError => e
      Rails.logger.error("[AgentKit::EmbeddingJob] Embedding failed: #{e.message}")
      nil
    end
  end
end
