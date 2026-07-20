# frozen_string_literal: true

module AgentSketch
  # Holds global configuration for AgentSketch.
  # Set via AgentSketch.configure { |c| ... }
  class Configuration
    attr_reader :llm_config, :vector_config, :state_config, :tracing_config,
                :embeddings_config

    def initialize
      @llm_config       = {}
      @vector_config    = {}
      @state_config     = { backend: :memory }
      @tracing_config   = []
      @embeddings_config = {}
    end

    # Configure LLM provider credentials.
    # Delegates to RubyLLM.configure underneath.
    #
    # @yield [LlmConfig] a simple struct-like builder
    def llm
      builder = LlmConfigBuilder.new(@llm_config)
      yield builder
    end

    # Configure vector store for RAG and episodic memory.
    #
    # @param backend [Symbol] :pgvector | :qdrant | :chroma
    # @param opts    [Hash]   backend-specific options
    def vector(backend, **opts)
      @vector_config = { backend: backend, **opts }
    end

    # Configure state backend for pausable workflows.
    #
    # @param backend [Symbol] :memory | :redis
    # @param opts    [Hash]   backend-specific options
    def state(backend, **opts)
      @state_config = { backend: backend, **opts }
    end

    # Configure tracing / observability backend.
    #
    # @param backend [Symbol] :file | :otlp | :stdout
    # @param opts    [Hash]   backend-specific options
    def tracing(backend, **opts)
      @tracing_config << { backend: backend, **opts }
    end

    # Configure the default embeddings model.
    #
    # @param model [String]
    def embeddings(model:)
      @embeddings_config = { model: model }
    end

    # Simple builder yielded in the #llm block
    class LlmConfigBuilder
      KEYS = %i[
        openai_api_key anthropic_api_key ollama_api_base
        mistral_api_key gemini_api_key groq_api_key
        deepseek_api_key openai_api_base google_api_key
      ].freeze

      def initialize(store)
        @store = store
      end

      KEYS.each do |key|
        define_method(:"#{key}=") { |v| @store[key] = v }
        define_method(key)        { @store[key] }
      end
    end
  end
end
