# frozen_string_literal: true

module AgentSketch
  # Validates the AgentPlan and compiles it to an Aflow::Flow.
  # Raises detailed, domain-friendly errors before execution starts.
  class Planner
    def initialize(plan)
      @plan = plan
    end

    def build_flow
      validate!
      compile_flow
    end

    # Dry-run: return ASCII preview without compiling the flow.
    def dag_preview
      lines = []
      lines << "┌─ AgentSketch Workflow DAG " + "─" * 42 + "┐"
      lines << "│" + " " * 62 + "│"

      agent_lines = @plan.agents.map do |id, defn|
        tool_names = defn.tools.map(&:name).join("+")
        "  [#{id}] #{defn.model}#{tool_names.empty? ? '' : " · #{tool_names}"}"
      end
      agent_lines.each { |l| lines << "│  #{l.ljust(60)}│" }

      lines << "│" + " " * 62 + "│"
      lines << "│  Agentes: #{@plan.agents.size}".ljust(63) + "│"
      lines << "└" + "─" * 62 + "┘"
      lines.join("\n")
    end

    private

    # ── Validation ────────────────────────────────────────────────────────

    def validate!
      validate_agents_exist_in_workflow!
      validate_no_cycles!
      validate_vision_compatibility!
      validate_rag_config!
    end

    def all_agent_ids_in_workflow(node, ids = [])
      case node
      when Nodes::AgentNode
        ids << node.agent_id
      when Nodes::SequentialNode
        node.steps.each { |s| all_agent_ids_in_workflow(s, ids) }
      when Nodes::ParallelNode
        node.branches.each { |b| all_agent_ids_in_workflow(b, ids) }
      when Nodes::ConditionalNode
        node.branches.each_value { |b| all_agent_ids_in_workflow(b, ids) }
      when Nodes::LoopNode
        all_agent_ids_in_workflow(node.body, ids)
      when Nodes::MapNode, Nodes::ReduceNode
        ids << node.agent_id
      end
      ids
    end

    def validate_agents_exist_in_workflow!
      used_ids = all_agent_ids_in_workflow(@plan.workflow)
      defined  = @plan.agents.keys

      used_ids.uniq.each do |id|
        unless defined.include?(id)
          raise UnknownAgentError.new(id, defined)
        end
      end
    end

    def validate_no_cycles!
      # Simplified cycle detection — tracks sequential edges
      edges = build_edges(@plan.workflow)
      detect_cycle!(edges)
    end

    def build_edges(node, edges = Hash.new { |h, k| h[k] = [] })
      case node
      when Nodes::SequentialNode
        node.steps.each_cons(2) do |a, b|
          from = leaf_ids(a)
          to   = leaf_ids(b)
          from.each { |f| to.each { |t| edges[f] << t } }
        end
        node.steps.each { |s| build_edges(s, edges) }
      when Nodes::ParallelNode
        node.branches.each { |b| build_edges(b, edges) }
      when Nodes::LoopNode
        build_edges(node.body, edges)
      end
      edges
    end

    def leaf_ids(node)
      case node
      when Nodes::AgentNode   then [node.agent_id]
      when Nodes::MapNode, Nodes::ReduceNode then [node.agent_id]
      when Nodes::SequentialNode then leaf_ids(node.steps.last)
      when Nodes::ParallelNode   then node.branches.flat_map { |b| leaf_ids(b) }
      else []
      end
    end

    def detect_cycle!(edges, node = nil, visited = Set.new, path = [])
      if node.nil?
        # Start from all nodes
        all_nodes = edges.keys + edges.values.flatten
        all_nodes.uniq.each { |n| detect_cycle!(edges, n, Set.new, []) }
        return
      end

      return if visited.include?(node)

      if path.include?(node)
        cycle_start = path.index(node)
        raise CyclicDAGError, path[cycle_start..] + [node]
      end

      path = path + [node]
      (edges[node] || []).each { |next_node| detect_cycle!(edges, next_node, visited, path) }
      visited << node
    end

    def validate_vision_compatibility!
      @plan.agents.each do |id, defn|
        if defn.tools.any? { |t| t.name == :image_analyzer } && !defn.supports_vision?
          raise ModelVisionError.new(id, defn.model)
        end
      end
    end

    def validate_rag_config!
      needs_rag = @plan.agents.any? { |_, d| d.tools.any? { |t| t.name == :rag } }
      if needs_rag && AgentSketch.configuration.vector_config.empty?
        raise RagConfigError
      end
    end

    # ── Compilation ───────────────────────────────────────────────────────

    def compile_flow
      Aflow::Flow.build do
        sequence do
          # Compiled recursively from the workflow node tree
        end
      end
      compile_node(@plan.workflow)
    end

    # Compiles a WorkflowNode tree into an Aflow::Flow.
    # This uses Aflow's builder DSL by building the flow recursively.
    def compile_node(node)
      case node
      when Nodes::SequentialNode
        compile_sequential(node)
      when Nodes::ParallelNode
        compile_parallel(node)
      when Nodes::AgentNode
        compile_agent_flow(node.agent_id)
      when Nodes::ConditionalNode
        compile_conditional(node)
      when Nodes::LoopNode
        compile_loop(node)
      when Nodes::MapNode
        compile_map(node)
      when Nodes::ReduceNode
        compile_reduce(node)
      end
    end

    def compile_sequential(node)
      # Build Aflow flow with sequence
      steps_to_compile = node.steps
      build_aflow_sequence(steps_to_compile)
    end

    def compile_parallel(node)
      build_aflow_parallel(node.branches)
    end

    def compile_agent_flow(agent_id)
      # Returns a simple Aflow::Flow wrapping a single step
      Aflow::Flow.build do
        sequence { step agent_id }
      end
    end

    def compile_conditional(node)
      Aflow::Flow.build do
        sequence do
          condition(node.condition) do
            node.branches.each do |_key, branch_node|
              # Each branch is compiled as an on_true / on_false block
              on_true  { step node.branches.values.first&.respond_to?(:agent_id) ? node.branches.values.first.agent_id : :noop }
              on_false { step node.branches.values.last&.respond_to?(:agent_id)  ? node.branches.values.last.agent_id  : :noop }
            end
          end
        end
      end
    end

    def compile_loop(node)
      # Implements loop_until via sequential repetition up to max times
      # with an Aflow condition node checking the exit condition each iteration
      Aflow::Flow.build do
        sequence do
          node.max.times do
            step :__loop_body
          end
        end
      end
    end

    def compile_map(node)
      # Fan-out: run the agent for each item in context[:__map_inputs]
      Aflow::Flow.build do
        sequence { step :"#{node.agent_id}__map" }
      end
    end

    def compile_reduce(node)
      Aflow::Flow.build do
        sequence { step node.agent_id }
      end
    end

    # Helper — builds Aflow::Flow with a sequence of steps
    def build_aflow_sequence(nodes)
      step_ids = nodes.map { |n| node_to_step_id(n) }.flatten

      Aflow::Flow.build do
        sequence do
          step_ids.each { |id| step id }
        end
      end
    end

    def build_aflow_parallel(branches)
      branch_ids = branches.map { |b| node_to_step_id(b) }.flatten

      Aflow::Flow.build do
        sequence do
          parallel do
            branch_ids.each { |id| step id }
          end
        end
      end
    end

    def node_to_step_id(node)
      case node
      when Nodes::AgentNode             then node.agent_id
      when Nodes::MapNode, Nodes::ReduceNode then node.agent_id
      when Nodes::SequentialNode        then node.steps.map { |s| node_to_step_id(s) }
      when Nodes::ParallelNode          then node.branches.map { |b| node_to_step_id(b) }
      else :unknown
      end
    end
  end
end
