# frozen_string_literal: true

module AgentSketch
  module Nodes
    # A leaf in the DAG — refers to a single declared agent.
    class AgentNode
      attr_reader :agent_id

      def initialize(agent_id)
        @agent_id = agent_id
      end

      # DSL operator: sequential composition
      def >>(other)
        SequentialNode.new([self, other])
      end

      # DSL operator: parallel composition
      def |(other)
        # Flatten into a single ParallelNode if possible
        branches = [self, other].flat_map do |n|
          n.is_a?(ParallelNode) ? n.branches : [n]
        end
        ParallelNode.new(branches)
      end
    end

    # Two or more nodes run left-to-right; output of each feeds the next.
    class SequentialNode
      attr_reader :steps

      def initialize(steps)
        @steps = steps.flat_map { |s| s.is_a?(SequentialNode) ? s.steps : [s] }
      end

      def >>(other)
        SequentialNode.new(@steps + [other])
      end

      def |(other)
        branches = [self, other].flat_map do |n|
          n.is_a?(ParallelNode) ? n.branches : [n]
        end
        ParallelNode.new(branches)
      end
    end

    # Two or more nodes run concurrently; outputs are merged before the next step.
    class ParallelNode
      attr_reader :branches

      def initialize(branches)
        @branches = branches
      end

      def >>(other)
        SequentialNode.new([self, other])
      end
    end

    # Evaluates a lambda against the current context and routes to the matching agent.
    class ConditionalNode
      attr_reader :condition, :branches

      # @param condition [Proc]   ->(ctx) { :agent_id }
      # @param branches  [Hash]   { agent_id => WorkflowNode }
      def initialize(condition, branches)
        @condition = condition
        @branches  = branches
      end

      def >>(other)
        SequentialNode.new([self, other])
      end
    end

    # Repeats the body until the condition is met or max iterations is reached.
    class LoopNode
      attr_reader :body, :condition, :max

      def initialize(body, condition, max)
        @body      = body
        @condition = condition
        @max       = max
      end

      def >>(other)
        SequentialNode.new([self, other])
      end
    end

    # Distributes a list of inputs across parallel instances of a single agent.
    class MapNode
      attr_reader :agent_id

      def initialize(agent_id)
        @agent_id = agent_id
      end

      def >>(other)
        SequentialNode.new([self, other])
      end
    end

    # Aggregates the array outputs of a MapNode into a single result.
    class ReduceNode
      attr_reader :agent_id

      def initialize(agent_id)
        @agent_id = agent_id
      end

      def >>(other)
        SequentialNode.new([self, other])
      end
    end
  end
end
