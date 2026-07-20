# frozen_string_literal: true

module AgentSketch
  # Maintains a catalogue of available tools (built-in and custom).
  # Resolves ToolSpec arrays into live RubyLLM::Tool instances.
  module ToolRegistry
    BUILT_IN = {
      web_search:    -> (opts) { Tools::WebSearch.new(opts) },
      rag:           -> (opts) { Tools::RAG.new(opts) },
      calculator:    -> (opts) { Tools::Calculator.new(opts) },
      text_editor:   -> (opts) { Tools::TextEditor.new(opts) },
      file_reader:   -> (opts) { Tools::FileReader.new(opts) },
      code_runner:   -> (opts) { Tools::CodeRunner.new(opts) },
      image_analyzer:-> (opts) { Tools::ImageAnalyzer.new(opts) },
      memory_search: -> (opts) { Tools::MemorySearch.new(opts) },
    }.freeze

    @custom = {}

    class << self
      # Register a custom tool factory.
      # @param name    [Symbol]
      # @param factory [Proc] ->(opts) { RubyLLM::Tool instance }
      def register(name, &factory)
        @custom[name.to_sym] = factory
      end

      # Resolve an array of ToolSpec into RubyLLM::Tool instances.
      # @param specs [Array<Nodes::ToolSpec>]
      # @return      [Array<RubyLLM::Tool>]
      def resolve(specs)
        specs.map do |spec|
          if spec.block
            build_inline_tool(spec)
          else
            factory = BUILT_IN[spec.name] || @custom[spec.name]
            raise UnknownToolError, spec.name unless factory

            factory.call(spec.options)
          end
        end
      end

      private

      # Dynamically build a RubyLLM::Tool subclass from an inline DSL block.
      def build_inline_tool(spec)
        tool_class = Class.new(RubyLLM::Tool) do
          @_spec = spec

          class << self
            def description(text = nil)
              if text
                @_description = text
              else
                @_description || @_spec.options[:description].to_s
              end
            end

            def _execute_block=(blk)
              @_execute_block = blk
            end

            def _execute_block
              @_execute_block
            end
          end

          define_method(:execute) do |**args|
            instance_exec(**args, &self.class._execute_block)
          end
        end

        builder = InlineToolBuilder.new(tool_class, spec.options)
        spec.block.call(builder) if spec.block
        tool_class.new
      end
    end

    # Yielded when defining an inline custom tool in the DSL
    class InlineToolBuilder
      def initialize(tool_class, opts)
        @tool_class = tool_class
        @opts       = opts
      end

      def description(text)
        @tool_class.define_singleton_method(:description) { text }
      end

      def param(name, type: :string, required: true, default: nil, desc: "")
        # Delegate to RubyLLM::Tool.param class macro
        @tool_class.param(name, desc: desc)
      end

      def execute(&blk)
        @tool_class._execute_block = blk
      end
    end
  end
end
