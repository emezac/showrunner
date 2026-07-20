# frozen_string_literal: true

require_relative "aflow/version"
require_relative "aflow/step_result"
require_relative "aflow/context"
require_relative "aflow/step"
require_relative "aflow/nodes"
require_relative "aflow/trace"
require_relative "aflow/executor"
require_relative "aflow/flow"
require_relative "aflow/mcp"

module Aflow
  # Convenience helper — build a Flow inline without .build:
  #
  #   Aflow.flow(registry: { ... }) { sequence { step :a; step :b } }
  def self.flow(registry: {}, &block)
    Flow.build(registry: registry, &block)
  end
end
