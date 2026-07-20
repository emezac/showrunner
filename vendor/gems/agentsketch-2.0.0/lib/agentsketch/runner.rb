# frozen_string_literal: true

module AgentSketch
  # Connects a validated AgentPlan with Aflow's execution engine.
  # Builds the step registry, runs the flow, and wraps the result.
  class Runner
    def initialize(plan, options)
      @plan    = plan
      @options = options
    end

    def run(input)
      if @options[:dry_run]
        preview = Planner.new(@plan).dag_preview
        return RunResult.new(
          output:  preview,
          trace:   nil,
          cost:    { tokens: { total: 0 }, usd: 0.0 },
          success: true,
          errors:  []
        )
      end

      flow     = build_flow
      registry = build_registry
      context  = build_initial_context(input)

      run_opts = { registry: registry, initial_context: context }
      run_opts[:replay_trace] = @options[:replay_trace] if @options[:replay_trace]

      final_context, trace = flow.run(**run_opts)

      if @options[:verbose]
        print_trace(trace)
      end

      RunResult.new(
        output:  final_context[:__last_output],
        trace:   trace,
        cost:    extract_cost(trace),
        success: trace.success?,
        errors:  extract_errors(trace)
      )
    rescue Aflow::Executor::HaltError => e
      raise AgentSketch::RuntimeError, "Workflow halted: #{e.message}"
    end

    private

    def build_flow
      # Build Aflow::Flow from the workflow node tree
      workflow = @plan.workflow
      build_aflow_from_node(workflow)
    end

    def build_aflow_from_node(node)
      runner = self
      case node
      when Nodes::SequentialNode
        steps = node.steps
        Aflow::Flow.build do
          sequence do
            steps.each { |s| runner.send(:step_or_sub, s, self) }
          end
        end
      when Nodes::ParallelNode
        branch_ids = node.branches.map { |b| runner.send(:node_to_id, b) }
        Aflow::Flow.build do
          sequence do
            parallel do
              branch_ids.each { |id| step id }
            end
          end
        end
      when Nodes::AgentNode
        id = node.agent_id
        Aflow::Flow.build do
          sequence { step id }
        end
      when Nodes::ConditionalNode
        cond     = node.condition
        branches = node.branches
        true_id  = branches[:true_branch]&.respond_to?(:agent_id) ? branches[:true_branch].agent_id : nil
        false_id = branches[:false_branch]&.respond_to?(:agent_id) ? branches[:false_branch].agent_id : nil
        Aflow::Flow.build do
          sequence do
            condition(cond) do
              on_true  { step true_id  } if true_id
              on_false { step false_id } if false_id
            end
          end
        end
      when Nodes::LoopNode
        body_node = node.body
        cond      = node.condition
        max_iter  = node.max
        # Implement as sequential steps with inline condition check
        Aflow::Flow.build do
          sequence do
            max_iter.times { runner.send(:step_or_sub, body_node, self) }
          end
        end
      when Nodes::MapNode
        id = node.agent_id
        Aflow::Flow.build do
          sequence { step :"#{id}__map" }
        end
      when Nodes::ReduceNode
        id = node.agent_id
        Aflow::Flow.build do
          sequence { step id }
        end
      else
        raise PlanError, "Unknown workflow node type: #{node.class}"
      end
    end

    def node_to_id(node)
      case node
      when Nodes::AgentNode             then node.agent_id
      when Nodes::MapNode, Nodes::ReduceNode then node.agent_id
      when Nodes::SequentialNode        then node.steps.first && node_to_id(node.steps.first)
      else :unknown
      end
    end

    # Used inside Aflow::Flow.build blocks to inline sub-sequences or single steps
    def step_or_sub(node, builder)
      case node
      when Nodes::AgentNode
        builder.step(node.agent_id)
      when Nodes::MapNode
        builder.step(:"#{node.agent_id}__map")
      when Nodes::ReduceNode
        builder.step(node.agent_id)
      when Nodes::SequentialNode
        node.steps.each { |s| step_or_sub(s, builder) }
      when Nodes::ParallelNode
        branch_ids = node.branches.map { |b| node_to_id(b) }
        builder.parallel do
          branch_ids.each { |id| step id }
        end
      end
    end

    def build_registry
      @plan.agents.each_with_object({}) do |(name, agent_def), registry|
        tools = ToolRegistry.resolve(agent_def.tools)
        step  = Steps::AgentStep.new(agent_def, tools)

        # Apply resilience config from the AgentDefinition
        step.class.config(
          retry:    agent_def.retry_policy.to_aflow_config,
          timeout:  agent_def.timeout,
          fallback: agent_def.fallback&.to_s,
          on_error: agent_def.fallback ? :continue : :halt
        ) if step.class.respond_to?(:config)

        registry[name] = step
      end
    end

    def build_initial_context(input)
      Aflow::Context.new(
        data: {
          input:  input,
          run_id: SecureRandom.hex(8)
        },
        metadata: {
          env:       ENV.fetch("RACK_ENV", "development"),
          started_at: Time.now.iso8601
        }
      )
    end

    def extract_cost(trace)
      return { tokens: { total: 0 }, usd: 0.0 } unless trace

      total_prompt     = 0
      total_completion = 0

      trace.events.each do |event|
        m = event.metrics || {}
        total_prompt     += (m[:prompt_tokens]     || 0).to_i
        total_completion += (m[:completion_tokens] || 0).to_i
      end

      total_tokens = total_prompt + total_completion

      # Rough cost estimate — override with ruby_llm model registry when available
      usd = (total_prompt * 0.000_005) + (total_completion * 0.000_015)

      {
        tokens: { prompt: total_prompt, completion: total_completion, total: total_tokens },
        usd:    usd.round(6)
      }
    end

    def extract_errors(trace)
      return [] unless trace

      trace.events
           .select { |e| e.status == :error }
           .map    { |e| { step: e.step_id, error: e.output_snapshot&.dig(:error) } }
    end

    def print_trace(trace)
      puts "\n── AgentSketch Trace ──────────────────────────────────"
      trace.events.each do |event|
        status_icon = event.status == :success ? "✓" : "✗"
        puts "  #{status_icon} #{event.step_id}: #{event.status} (#{event.duration_ms}ms)"
        event.logs.each { |log| puts "      #{log}" }
      end
      puts "  Total: #{trace.total_duration_ms}ms | Success: #{trace.success?}"
      puts "──────────────────────────────────────────────────────\n"
    end
  end
end
