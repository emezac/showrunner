# frozen_string_literal: true

module Aflow
  # Main entry point. Build a flow with the DSL, register steps, then run.
  #
  #   flow = Aflow::Flow.build do
  #     sequence do
  #       step :fetch
  #       parallel do
  #         step :analyze
  #         step :summarize
  #       end
  #       step :store
  #     end
  #   end
  #
  #   registry = {
  #     fetch:    FetchStep.new,
  #     analyze:  AnalyzeStep.new,
  #     summarize: SummarizeStep.new,
  #     store:    StoreStep.new
  #   }
  #
  #   context, trace = flow.run(
  #     registry: registry,
  #     initial_context: Aflow::Context.new(data: { url: "https://example.com" })
  #   )
  class Flow
    attr_reader :root, :registry

    def initialize(root, registry: {})
      @root     = root
      @registry = registry
    end

    # DSL builder — define the graph structure in a block.
    def self.build(registry: {}, &block)
      builder = Builder.new
      builder.instance_eval(&block)
      new(builder.root, registry: registry)
    end

    # Register steps after construction.
    def register(steps_hash)
      @registry = @registry.merge(steps_hash)
      self
    end

    # Execute the flow.
    #
    # @param registry        [Hash]           override or extend the flow's registry
    # @param initial_context [Aflow::Context] starting context (default: empty)
    # @param replay_trace    [Aflow::Trace]   optional — replays from a previous trace
    # @return [Array(Aflow::Context, Aflow::Trace)]
    def run(registry: {}, initial_context: Context.new, replay_trace: nil)
      merged_registry = @registry.merge(registry)

      Executor.new(
        root,
        registry:     merged_registry,
        replay_trace: replay_trace
      ).run(initial_context: initial_context)
    end

    def inspect
      "#<Aflow::Flow root=#{root.type}>"
    end

    # ─────────────────────────────────────────────────────────────────────
    # DSL Builder
    # ─────────────────────────────────────────────────────────────────────
    class Builder
      attr_reader :root

      def sequence(&block)
        node = Nodes::Sequence.new
        build_children(node, &block)
        @root ||= node
        node
      end

      def parallel(&block)
        node = Nodes::Parallel.new
        build_children(node, &block)
        @root ||= node
        node
      end

      def step(id)
        node = Nodes::StepNode.new(id)
        @root ||= node
        node
      end

      # Conditional branch.
      #
      #   condition ->(ctx) { ctx[:score] > 0.5 } do
      #     on_true  { step :approve }
      #     on_false { step :reject  }
      #   end
      def condition(predicate, &block)
        cb = ConditionalBuilder.new
        cb.instance_eval(&block) if block
        node = Nodes::Conditional.new(
          condition: predicate,
          on_true:   cb.on_true_node,
          on_false:  cb.on_false_node
        )
        @root ||= node
        node
      end

      private

      def build_children(parent, &block)
        child_builder = ChildBuilder.new(parent)
        child_builder.instance_eval(&block) if block
      end
    end

    # Adds children to a parent node via the DSL
    class ChildBuilder
      def initialize(parent)
        @parent = parent
      end

      def step(id)
        node = Nodes::StepNode.new(id)
        @parent.add(node)
        node
      end

      def sequence(&block)
        node = Nodes::Sequence.new
        @parent.add(node)
        build_children(node, &block)
        node
      end

      def parallel(&block)
        node = Nodes::Parallel.new
        @parent.add(node)
        build_children(node, &block)
        node
      end

      def condition(predicate, &block)
        cb = ConditionalBuilder.new
        cb.instance_eval(&block) if block
        node = Nodes::Conditional.new(
          condition: predicate,
          on_true:   cb.on_true_node,
          on_false:  cb.on_false_node
        )
        @parent.add(node)
        node
      end

      private

      def build_children(parent, &block)
        child_builder = ChildBuilder.new(parent)
        child_builder.instance_eval(&block) if block
      end
    end

    # Builds the on_true / on_false branches for a Conditional node
    class ConditionalBuilder
      attr_reader :on_true_node, :on_false_node

      def on_true(&block)
        builder = Builder.new
        builder.instance_eval(&block)
        @on_true_node = builder.root
      end

      def on_false(&block)
        builder = Builder.new
        builder.instance_eval(&block)
        @on_false_node = builder.root
      end
    end
  end
end
