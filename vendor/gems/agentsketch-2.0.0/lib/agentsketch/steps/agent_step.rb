# frozen_string_literal: true

module AgentSketch
  module Steps
    # The core execution unit. Each declared agent compiles to an AgentStep.
    # Inherits from Aflow::Step so it gets retry, timeout, fallback, and tracing for free.
    class AgentStep < Aflow::Step
      def initialize(agent_def, tool_instances)
        @agent_def      = agent_def
        @tool_instances = tool_instances
        @memory         = Memory::Manager.for_spec(agent_def.memory, agent_id: agent_def.name)
        super()
      end

      def id
        @agent_def.name.to_s
      end

      def call(context)
        input = context[:__last_output] || context[:input] || ""

        chat     = build_chat(context)
        response = chat.ask(input)

        @memory.save(input, response.content)

        output_value = format_output(response.content)

        Aflow::StepResult.success(
          output:  {
            __last_output:                       output_value,
            :"#{@agent_def.name}_output" =>      output_value
          },
          logs:    ["#{id}: completado (#{response.input_tokens.to_i + response.output_tokens.to_i} tokens)"],
          metrics: {
            tokens:             response.input_tokens.to_i + response.output_tokens.to_i,
            prompt_tokens:      response.input_tokens || 0,
            completion_tokens:  response.output_tokens || 0,
            model:              @agent_def.model
          }
        )
      rescue StandardError => e
        Aflow::StepResult.error(
          error: e,
          logs:  ["#{id} falló: #{e.class}: #{e.message}"]
        )
      end

      private

      def build_chat(context)
        memory_context = @memory.build_context(
          context[:__last_output] || context[:input] || ""
        )
        system_prompt = build_system_prompt(memory_context)

        chat = RubyLLM.chat(model: @agent_def.model)
        chat.with_temperature(@agent_def.temperature) if @agent_def.temperature
        chat.with_instructions(system_prompt)
        chat.with_tools(*@tool_instances) unless @tool_instances.empty?
        chat.with_params(max_tokens: @agent_def.max_tokens) if @agent_def.max_tokens
        chat
      end

      def build_system_prompt(memory_context)
        parts = [@agent_def.role]
        parts << "Objetivo: #{@agent_def.goal}"  if @agent_def.goal
        parts << @agent_def.persona               if @agent_def.persona

        if @agent_def.output_format == :json
          parts << "Responde ÚNICAMENTE con JSON válido, sin texto adicional."
        elsif @agent_def.output_format == :structured && @agent_def.output_schema
          parts << "Responde ÚNICAMENTE con JSON válido con este esquema: #{@agent_def.output_schema.inspect}"
        end

        parts << "\n#{memory_context}" unless memory_context.to_s.empty?
        parts.join("\n\n")
      end

      def format_output(content)
        return content unless [:json, :structured].include?(@agent_def.output_format)

        begin
          JSON.parse(content)
        rescue JSON::ParserError
          content
        end
      end
    end
  end
end
