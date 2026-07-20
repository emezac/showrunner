# frozen_string_literal: true

require "rspec"

# Load AgentSketch with stub dependencies
# Stub aflow and ruby_llm so specs don't need real gems installed
module Aflow
  class Step
    def self.config(**opts); end
  end

  class StepResult
    attr_reader :status, :output, :logs, :metrics

    def initialize(status:, output: {}, logs: [], metrics: {}, error: nil)
      @status  = status
      @output  = output
      @logs    = logs
      @metrics = metrics
      @error   = error
    end

    def self.success(output: {}, logs: [], metrics: {})
      new(status: :success, output: output, logs: logs, metrics: metrics)
    end

    def self.error(error:, logs: [])
      new(status: :error, error: error, logs: logs)
    end

    def self.skip(logs: [])
      new(status: :skip, logs: logs)
    end

    def self.retry(logs: [])
      new(status: :retry, logs: logs)
    end
  end

  class Context
    def initialize(data: {}, metadata: {})
      @data     = data
      @metadata = metadata
    end

    def [](key)
      @data[key]
    end

    def key?(key)
      @data.key?(key)
    end
  end

  class Flow
    def self.build(&block)
      new
    end

    def run(**opts)
      ctx   = opts[:initial_context] || Context.new
      trace = double("Trace",
        success?:          true,
        total_duration_ms: 100,
        events:            [],
        to_h:              {}
      )
      [ctx, trace]
    end
  end

  class Executor
    class HaltError < StandardError; end
  end
end

module RubyLLM
  def self.chat(**opts)
    double("Chat")
  end

  def self.embed(text)
    double("Embedding", vectors: Array.new(1536) { rand })
  end

  def self.configure
    yield if block_given?
  end

  class Tool
    def self.description(text = nil)
      @description = text if text
      @description
    end

    def self.param(name, **opts)
    end

    def initialize
    end
  end
end

require_relative "../lib/agent_sketch"

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.disable_monkey_patching!
  config.warnings = false
  config.default_formatter = "doc" if config.files_to_run.one?
  config.order = :random
  Kernel.srand config.seed
end
