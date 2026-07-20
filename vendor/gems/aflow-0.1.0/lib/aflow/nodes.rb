# frozen_string_literal: true

module Aflow
  module Nodes
    # Base node interface
    class Base
      attr_reader :children

      def initialize
        @children = []
      end

      def add(node)
        @children << node
        self
      end
    end

    # Executes children one after another, threading context through.
    class Sequence < Base
      def type = :sequence
    end

    # Executes children concurrently using threads; merges outputs.
    class Parallel < Base
      def type = :parallel
    end

    # Wraps a single registered Step.
    class StepNode < Base
      attr_reader :step_id

      def initialize(step_id)
        super()
        @step_id = step_id
      end

      def type = :step
    end

    # Branches to one of two sub-graphs based on a predicate.
    class Conditional < Base
      attr_reader :condition, :on_true, :on_false

      # condition: a callable (Proc/Lambda) that receives Context and returns truthy/falsy
      def initialize(condition:, on_true:, on_false: nil)
        super()
        @condition = condition
        @on_true   = on_true
        @on_false  = on_false
      end

      def type = :conditional
    end
  end
end
