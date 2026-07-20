# frozen_string_literal: true

module Agentkit
  # Routes agent requests to the appropriate LLM model string.
  #
  # Profiles:
  #   :fast     — low-latency, high-frequency calls (e.g. suggestions, tagging)
  #   :default  — balanced quality/cost (most domain agents)
  #   :complex  — maximum reasoning (deep analysis, synthesis, strategy)
  #   :code     — code generation (Fábrica / CodificadorAgent)
  #   :vision   — multimodal / document parsing
  #
  # Usage:
  #   Agentkit::ModelRouter.resolve(:complex)  # => "claude-opus-4-6"
  #   Agentkit::ModelRouter.resolve(nil)       # => config.llm_default_model
  class ModelRouter
    PROFILES = %i[fast default complex code vision].freeze

    class << self
      # Resolve a profile symbol or explicit model string.
      # If model is already a String, pass it through unchanged.
      def resolve(profile_or_model)
        return profile_or_model if profile_or_model.is_a?(String)

        cfg = Agentkit.config

        case profile_or_model&.to_sym
        when :fast    then cfg.llm_fast_model
        when :complex then cfg.llm_complex_model
        when :code    then cfg.llm_code_model
        when :vision  then cfg.llm_vision_model
        else               cfg.llm_default_model
        end
      end

      # Return all configured model strings, deduplicated.
      def all_models
        cfg = Agentkit.config
        [
          cfg.llm_default_model,
          cfg.llm_fast_model,
          cfg.llm_complex_model,
          cfg.llm_code_model,
          cfg.llm_vision_model
        ].uniq.compact
      end
    end
  end
end
