# frozen_string_literal: true

module Agentkit
  # Central configuration object for the AgentKit engine.
  # Set via Agentkit.configure in config/initializers/agentkit.rb
  #
  # Example:
  #   Agentkit.configure do |config|
  #     config.domain_name       = "LegalSketch"
  #     config.primary_entity    = :caso
  #     config.llm_default_model = "claude-sonnet-4-6"
  #     config.hitl_level        = :strict
  #   end
  class Configuration
    # ─── Domain ──────────────────────────────────────────────────────────────
    attr_accessor :domain_name      # Human name shown in UI / logs
    attr_accessor :primary_entity   # Symbol — e.g. :caso, :patient, :project

    # ─── LLM routing ─────────────────────────────────────────────────────────
    # Profiles: fast / default / complex / code / vision
    # The ModelRouter maps profiles to these model strings.
    attr_accessor :llm_default_model   # Balanced — most agent calls
    attr_accessor :llm_fast_model      # Cheap/quick — high-frequency tasks
    attr_accessor :llm_complex_model   # Powerful — deep analysis, synthesis
    attr_accessor :llm_code_model      # Code generation (Fábrica)
    attr_accessor :llm_vision_model    # Multimodal — document parsing
    attr_accessor :embedding_model     # Vector embeddings for MemoryEngine

    # ─── API keys (override ENV vars if set here) ────────────────────────────
    attr_accessor :anthropic_api_key
    attr_accessor :openai_api_key
    attr_accessor :google_api_key
    attr_accessor :ollama_base_url

    # ─── HITL ────────────────────────────────────────────────────────────────
    # :strict    — every suggestion requires human approval before action
    # :advisory  — suggestions are visible but may auto-apply after timeout
    # :silent    — suggestions are logged only; no UI interruption
    attr_accessor :hitl_level

    # ─── Multi-tenancy ────────────────────────────────────────────────────────
    attr_accessor :multi_tenant       # Boolean — adds account_id scoping

    # ─── Dreaming / memory ───────────────────────────────────────────────────
    attr_accessor :dreaming_cron               # Cron string, e.g. "0 2 * * *"
    attr_accessor :dreaming_threshold          # Cosine distance for consolidation (0.0-1.0)
    attr_accessor :auto_consolidate            # Boolean — auto-apply high-confidence clusters
    attr_accessor :embedding_batch_size        # How many memories to embed per job run

    # ─── Feature flags ───────────────────────────────────────────────────────
    # Accepted symbols: :rag, :scraping, :scope_guard, :contracts, :content_gen,
    #                   :financial_health, :python_ml
    attr_accessor :features

    # ─── A2A / MCP ───────────────────────────────────────────────────────────
    attr_accessor :a2a_enabled        # Mount A2AController + 7 agent cards
    attr_accessor :a2a_secret_key     # X-A2A-Key header value
    attr_accessor :mcp_enabled        # Expose agents via MCP server

    def initialize
      # Safe defaults — production-ready without any configuration
      @domain_name         = "AgentKit App"
      @primary_entity      = :entity

      @llm_default_model   = "claude-sonnet-4-6"
      @llm_fast_model      = "gemini-2.5-flash"
      @llm_complex_model   = "claude-opus-4-6"
      @llm_code_model      = "claude-sonnet-4-6"
      @llm_vision_model    = "gemini-2.0-flash"
      @embedding_model     = "gemini-embedding-2"

      @hitl_level          = :strict    # Safe by default
      @multi_tenant        = false

      @dreaming_cron       = "0 2 * * *"
      @dreaming_threshold  = 0.25
      @auto_consolidate    = false
      @embedding_batch_size = 50

      @features            = []

      @a2a_enabled         = false
      @a2a_secret_key      = ENV.fetch("AGENTKIT_A2A_KEY", nil)
      @mcp_enabled         = false
    end

    # Convenience predicate helpers ─────────────────────────────────────────
    def feature?(name) = Array(@features).include?(name.to_sym)
    def strict_hitl?  = @hitl_level == :strict
    def advisory_hitl? = @hitl_level == :advisory
    def silent_hitl?  = @hitl_level == :silent
  end
end
