# frozen_string_literal: true

module AgentSketch
  module A2A
    # Wraps an external A2A agent as a RubyLLM::Tool so it can be used
    # directly in an agent's tool list.
    #
    # Usage in DSL:
    #   tool :legal_agent,
    #     a2a_url: "https://legal-agent.internal.com",
    #     description: "Consulta análisis legal a un agente externo"
    #
    # Or register manually:
    #   AgentSketch::A2A::ClientTool.register(
    #     name: :legal_agent,
    #     url: "https://legal-agent.internal.com",
    #     token: ENV["LEGAL_AGENT_TOKEN"]
    #   )
    class ClientTool < RubyLLM::Tool
      class << self
        # Register a ClientTool in the ToolRegistry pointing at an external A2A server.
        #
        # @param name        [Symbol]
        # @param url         [String]
        # @param token       [String, nil] Bearer token for auth
        # @param description [String]
        def register(name:, url:, token: nil, description: "Agente A2A externo")
          tool_name = name
          tool_url  = url
          tool_tok  = token
          tool_desc = description

          klass = Class.new(ClientTool) do
            @_a2a_url   = tool_url
            @_a2a_token = tool_tok

            define_singleton_method(:description) { tool_desc }
            define_singleton_method(:_a2a_url)    { @_a2a_url }
            define_singleton_method(:_a2a_token)  { @_a2a_token }
          end

          ToolRegistry.register(tool_name) { klass.new }
        end
      end

      description "Consulta a un agente A2A externo"
      param :query, desc: "La consulta o tarea a enviar al agente externo"

      def execute(query:)
        require_ruby_a2a!

        url   = self.class._a2a_url
        token = self.class._a2a_token

        client = RubyA2A::Client.new(url, auth: token ? RubyA2A::Auth::BearerToken.new(token) : nil)
        task   = client.send_message(query)

        # Poll until the task is completed
        completed = poll_until_done(client, task.id)

        extract_output(completed)
      rescue StandardError => e
        "Error al contactar agente A2A externo: #{e.message}"
      end

      private

      def require_ruby_a2a!
        require "ruby_a2a"
      rescue LoadError
        raise AgentSketch::ConfigurationError,
              "La gema 'ruby-a2a' es necesaria para usar agentes A2A externos. " \
              "Añade: gem 'ruby-a2a' en tu Gemfile"
      end

      def poll_until_done(client, task_id, timeout: 60, interval: 1)
        deadline = Time.now + timeout
        loop do
          task = client.get_task(task_id)
          return task if %w[completed failed cancelled].include?(task.status)
          raise "Timeout esperando respuesta del agente A2A" if Time.now > deadline

          sleep interval
        end
      end

      def extract_output(task)
        parts = task&.output&.parts || []
        text_parts = parts.select { |p| p["type"] == "text" || p.key?("text") }
        text_parts.map { |p| p["text"] || p["content"] }.join("\n")
      rescue StandardError
        task.to_s
      end
    end
  end
end
