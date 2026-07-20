# frozen_string_literal: true

module AgentSketch
  # Base error for all AgentSketch exceptions
  class Error < StandardError; end

  # Raised when configuration is missing or invalid (API keys, backends, etc.)
  class ConfigurationError < Error; end

  # Raised for DSL / plan-level problems (before execution starts)
  class PlanError < Error; end

  # Raised when an agent ID referenced in a workflow is not defined
  class UnknownAgentError < PlanError
    def initialize(agent_id, defined_agents = [])
      suggestions = defined_agents.map(&:to_s).join(", ")
      msg = "El agente ':#{agent_id}' no está definido."
      msg += " Agentes disponibles: #{suggestions}" unless suggestions.empty?
      super(msg)
    end
  end

  # Raised when a cycle is detected in the agent DAG
  class CyclicDAGError < PlanError
    def initialize(cycle_path)
      super("Ciclo detectado en el workflow: #{cycle_path.join(' → ')}")
    end
  end

  # Raised when a tool name is not found in ToolRegistry
  class UnknownToolError < PlanError
    def initialize(tool_name)
      super("Herramienta ':#{tool_name}' no registrada. " \
            "Herramientas built-in: #{ToolRegistry::BUILT_IN.keys.join(', ')}")
    end
  end

  # Raised when :image_analyzer is used with a model that doesn't support vision
  class ModelVisionError < PlanError
    def initialize(agent_id, model)
      super("El agente ':#{agent_id}' usa :image_analyzer pero " \
            "\"#{model}\" no soporta visión. " \
            "Modelos con visión: gpt-4o, claude-opus-4-5, claude-sonnet-4-6, gemini-1.5-pro")
    end
  end

  # Raised when :rag is used without a configured vector store
  class RagConfigError < ConfigurationError
    def initialize
      super(":rag requiere un vector store. " \
            "Añade: AgentSketch.configure { |c| c.vector :pgvector, connection: ENV['DATABASE_URL'] }")
    end
  end

  # Wraps Aflow runtime errors during execution
  class RuntimeError < Error; end

  # Raised when all retries are exhausted
  class MaxRetriesError < RuntimeError; end

  # Raised when a step exceeds its configured timeout
  class TimeoutError < RuntimeError; end

  # Raised when a tool fails definitively
  class ToolError < RuntimeError
    def initialize(tool_name, cause)
      super("La herramienta '#{tool_name}' falló: #{cause.message}")
    end
  end

  # Raised when structured output doesn't match the declared schema
  class OutputError < Error
    def initialize(agent_id, field, expected, got)
      super("Output del agente ':#{agent_id}' inválido. " \
            "Campo '#{field}': esperaba #{expected}, obtuvo #{got.class}")
    end
  end
end
