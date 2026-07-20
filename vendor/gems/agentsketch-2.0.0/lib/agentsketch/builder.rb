# frozen_string_literal: true

module AgentSketch
  # AgentPlan is the validated intermediate representation produced by Builder.
  AgentPlan = Data.define(:agents, :workflow, :config)

  # Parses the AgentSketch DSL block and produces an immutable AgentPlan.
  #
  # Usage:
  #   plan = Builder.build do
  #     agent :researcher do ... end
  #     agent :writer     do ... end
  #     workflow { researcher >> writer }
  #   end
  class Builder
    def self.build(&block)
      new.tap { |b| b.instance_eval(&block) }.to_plan
    end

    def initialize
      @agents   = {}
      @workflow = nil
      @config   = {}
    end

    # ── Agent definition ──────────────────────────────────────────────────

    def agent(name, &block)
      dsl = AgentDSL.new(name)
      dsl.instance_eval(&block)
      @agents[name] = dsl.to_definition
    end

    # ── Workflow definition ───────────────────────────────────────────────

    def workflow(&block)
      @workflow = WorkflowDSL.new(@agents.keys).instance_eval(&block)
    end

    # ── Tool definition (top-level custom tools) ──────────────────────────

    def tool(name, **opts, &block)
      ToolRegistry.register(name) { |o| build_custom_tool(name, opts.merge(o), block) }
    end

    def to_plan
      raise PlanError, "workflow do...end is required" unless @workflow

      AgentPlan.new(
        agents:   @agents.freeze,
        workflow: @workflow.freeze,
        config:   @config.freeze
      )
    end

    private

    def build_custom_tool(name, opts, block)
      spec = Nodes::ToolSpec.new(name: name, options: opts, block: block)
      ToolRegistry.resolve([spec]).first
    end
  end

  # ── Inner DSL for a single agent ─────────────────────────────────────────

  class AgentDSL
    def initialize(name)
      @name          = name
      @model         = "gpt-4o"
      @provider      = nil
      @role          = "Un agente de IA útil y preciso"
      @goal          = nil
      @persona       = nil
      @temperature   = 0.7
      @max_tokens    = nil
      @tools         = []
      @memory        = Nodes::MemorySpec.new(strategy: :sliding_window, options: { size: 10 })
      @retry_policy  = Nodes::DEFAULT_RETRY
      @timeout       = nil
      @fallback      = nil
      @output_format = :text
      @output_schema = nil
    end

    def model(m)         = (@model = m)
    def provider(p)      = (@provider = p)
    def role(r)          = (@role = r)
    def goal(g)          = (@goal = g)
    def persona(p)       = (@persona = p)
    def temperature(t)   = (@temperature = t)
    def max_tokens(n)    = (@max_tokens = n)
    def timeout(s)       = (@timeout = s)
    def fallback(a)      = (@fallback = a)
    def output_format(f) = (@output_format = f)
    def output_schema(s) = (@output_schema = s)

    # tools [:web_search, :rag]
    # tools :web_search, provider: :tavily, max_results: 5
    def tools(*names_or_specs, **opts)
      names_or_specs.flatten.each do |item|
        case item
        when Symbol
          @tools << Nodes::ToolSpec.new(name: item, options: opts, block: nil)
        when Hash
          item.each do |name, options|
            @tools << Nodes::ToolSpec.new(name: name, options: options, block: nil)
          end
        end
      end
    end

    # memory :sliding_window, size: 10
    def memory(strategy, **opts)
      @memory = Nodes::MemorySpec.new(strategy: strategy, options: opts)
    end

    # retry_policy max: 3, backoff: :exponential, on: [:rate_limit]
    def retry_policy(**opts)
      @retry_policy = Nodes::RetryPolicy.new(
        max:     opts.fetch(:max, 3),
        backoff: opts.fetch(:backoff, :exponential),
        on:      opts.fetch(:on, [])
      )
    end

    def to_definition
      Nodes::AgentDefinition.new(
        name:          @name,
        model:         @model,
        provider:      @provider,
        role:          @role,
        goal:          @goal,
        persona:       @persona,
        temperature:   @temperature,
        max_tokens:    @max_tokens,
        tools:         @tools,
        memory:        @memory,
        retry_policy:  @retry_policy,
        timeout:       @timeout,
        fallback:      @fallback,
        output_format: @output_format,
        output_schema: @output_schema
      )
    end
  end

  # ── Inner DSL for workflows ────────────────────────────────────────────────

  class WorkflowDSL
    def initialize(agent_ids)
      @agent_ids = agent_ids
    end

    # Each declared agent name becomes a method returning an AgentNode
    def method_missing(name, *args)
      if @agent_ids.include?(name)
        Nodes::AgentNode.new(name)
      else
        super
      end
    end

    def respond_to_missing?(name, include_private = false)
      @agent_ids.include?(name) || super
    end

    # route { |ctx| :some_agent }
    def route(branches = {}, &condition_block)
      Nodes::ConditionalNode.new(condition_block || ->(ctx) { nil }, branches)
    end

    # loop_until(max: 5, condition: ->(ctx) { ... }) do
    #   writer >> critic
    # end
    def loop_until(max: 10, condition:, &body_block)
      body = instance_eval(&body_block)
      Nodes::LoopNode.new(body, condition, max)
    end

    # map(:summarizer) — fan-out across input list
    def map(agent_id)
      Nodes::MapNode.new(agent_id)
    end

    # reduce(:synthesizer) — fan-in from MapNode outputs
    def reduce(agent_id)
      Nodes::ReduceNode.new(agent_id)
    end
  end
end
