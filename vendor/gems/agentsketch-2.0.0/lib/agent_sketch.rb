# frozen_string_literal: true

require "aflow"
require "ruby_llm"
require "securerandom"

require_relative "agentsketch/version"
require_relative "agentsketch/errors"
require_relative "agentsketch/configuration"
require_relative "agentsketch/nodes/agent_definition"
require_relative "agentsketch/nodes/tool_spec"
require_relative "agentsketch/nodes/memory_spec"
require_relative "agentsketch/nodes/retry_policy"
require_relative "agentsketch/nodes/workflow_nodes"
require_relative "agentsketch/tool_registry"
require_relative "agentsketch/memory/none"
require_relative "agentsketch/memory/sliding_window"
require_relative "agentsketch/memory/full"
require_relative "agentsketch/memory/summarize"
require_relative "agentsketch/memory/episodic"
require_relative "agentsketch/memory/manager"
require_relative "agentsketch/tools/web_search"
require_relative "agentsketch/tools/rag"
require_relative "agentsketch/tools/calculator"
require_relative "agentsketch/tools/text_editor"
require_relative "agentsketch/tools/file_reader"
require_relative "agentsketch/tools/code_runner"
require_relative "agentsketch/tools/image_analyzer"
require_relative "agentsketch/tools/memory_search"
require_relative "agentsketch/steps/agent_step"
require_relative "agentsketch/builder"
require_relative "agentsketch/planner"
require_relative "agentsketch/run_result"
require_relative "agentsketch/runner"

# A2A support (optional — loaded lazily to avoid hard dependency)
require_relative "agentsketch/a2a/server"
require_relative "agentsketch/a2a/client_tool"

module AgentSketch
  class << self
    # Primary entry point — run a multi-agent workflow.
    #
    # @param input    [String]  The initial input passed to the first agent
    # @param config   [String]  Path to YAML config file (optional)
    # @param verbose  [Boolean] Print trace events in real time
    # @param dry_run  [Boolean] Validate and preview DAG without executing
    # @param timeout  [Integer] Max seconds for the whole workflow
    # @param replay_trace [Aflow::Trace] Replay from a previous trace
    # @yield                    DSL block defining agents and workflow
    # @return [RunResult]
    def run(input: nil, config: nil, verbose: false, dry_run: false,
            timeout: 300, replay_trace: nil, &block)
      raise AgentSketch::PlanError, "A DSL block is required" unless block_given?

      load_config_file(config) if config

      plan    = Builder.build(&block)
      options = { verbose: verbose, dry_run: dry_run,
                  timeout: timeout, replay_trace: replay_trace }

      Runner.new(plan, options).run(input)
    end

    # Configure global settings (LLM keys, vector stores, observability, etc.)
    #
    # @yield [Configuration]
    def configure
      yield configuration
      apply_llm_configuration!
    end

    # Expose the workflow as an A2A HTTP server.
    #
    # @param port   [Integer]
    # @param host   [String]
    # @param name   [String]  Agent card name
    # @yield                  Same DSL block as .run
    def serve_a2a(port: 4567, host: "localhost", name: "AgentSketch Agent",
                  description: "Multi-agent workflow powered by AgentSketch", &block)
      raise AgentSketch::PlanError, "A DSL block is required" unless block_given?

      plan = Builder.build(&block)
      AgentSketch::A2A::Server.new(plan, port: port, host: host,
                                        name: name, description: description).start
    end

    # Expose the workflow as an MCP server (via Aflow::MCP).
    #
    # @yield  Same DSL block as .run
    def serve_mcp(name: "agentsketch_workflow",
                  description: "AgentSketch multi-agent workflow", &block)
      raise AgentSketch::PlanError, "A DSL block is required" unless block_given?

      require "aflow/mcp"
      plan   = Builder.build(&block)
      server = Aflow::MCP::Server.new
      server.flow(name, description: description) do |input|
        Runner.new(plan, {}).run(input)
      end
      transport = Aflow::MCP::Transport::Stdio.new(server)
      transport.start
    end

    # Ingest documents into a vector store for RAG.
    #
    # @yield [IngestBuilder]
    def ingest(&block)
      require_relative "agentsketch/ingester"
      Ingester.new.tap { |i| i.instance_eval(&block) }.run
    end

    def configuration
      @configuration ||= Configuration.new
    end

    def reset_configuration!
      @configuration = Configuration.new
    end

    private

    def load_config_file(path)
      require "yaml"
      data = YAML.safe_load_file(path, symbolize_names: true)
      # Map YAML keys → configure block
      configure do |c|
        if (llm = data[:llm])
          c.llm do |l|
            l.openai_api_key    = llm[:openai_api_key]    if llm[:openai_api_key]
            l.anthropic_api_key = llm[:anthropic_api_key] if llm[:anthropic_api_key]
            l.ollama_api_base   = llm[:ollama_api_base]   if llm[:ollama_api_base]
          end
        end
      end
    end

    def apply_llm_configuration!
      cfg = configuration.llm_config
      RubyLLM.configure do |c|
        c.openai_api_key    = cfg[:openai_api_key]    if cfg[:openai_api_key]
        c.anthropic_api_key = cfg[:anthropic_api_key] if cfg[:anthropic_api_key]
        c.ollama_api_base   = cfg[:ollama_api_base]   if cfg[:ollama_api_base]
        c.mistral_api_key   = cfg[:mistral_api_key]   if cfg[:mistral_api_key]
        c.gemini_api_key    = cfg[:gemini_api_key] || cfg[:google_api_key] if cfg[:gemini_api_key] || cfg[:google_api_key]
        c.groq_api_key      = cfg[:groq_api_key]      if cfg[:groq_api_key]
      end
    end
  end
end
