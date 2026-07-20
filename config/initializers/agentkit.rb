# frozen_string_literal: true

Agentkit.configure do |config|
  config.domain_name       = "AI Showrunner"
  config.primary_entity    = :project

  # LLM Model Routing
  # We use "qwen3.7-plus" for LLM tasks (confirmed working on this account).
  # Since qwen3.7-plus is set via OpenAI compatibility mode, we configure
  # openai_api_key in RubyLLM.
  config.llm_default_model = "qwen3.7-plus"
  config.llm_fast_model    = "qwen3.7-plus"
  config.llm_complex_model = "qwen3.7-plus"
  config.llm_code_model    = "qwen3.7-plus"
  config.llm_vision_model  = "qwen3.7-plus"
  config.embedding_model   = "text-embedding-v2" # Standard Qwen embedding model, stubbed below in development

  # Autonomy configuration
  config.hitl_level        = :strict # Suggest HITL cards for review
  config.multi_tenant      = false

  # Dreaming configuration
  config.dreaming_cron     = "0 2 * * *"
  config.dreaming_threshold = 0.25
  config.auto_consolidate  = false
end

# ─── Mock embeddings for development ──────────────────────────────────────────
# This ensures that memorization and pgvector search work seamlessly without
# consuming actual credits/tokens or requiring external setup.
if Rails.env.development? || Rails.env.test?
  require "ruby_llm"
  module RubyLLM
    class Embedding
      def self.embed(text, **args)
        # Generate a random unit vector for cosine distance computation
        vector = Array.new(1536) { rand - 0.5 }
        norm = Math.sqrt(vector.sum { |x| x * x })
        vector.map { |x| norm > 0 ? (x / norm).round(6) : 0.0 }
      end
    end
  end
end
