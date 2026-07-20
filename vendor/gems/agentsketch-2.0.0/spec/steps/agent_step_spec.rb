# frozen_string_literal: true

require "spec_helper"

RSpec.describe AgentSketch::Steps::AgentStep do
  let(:agent_def) do
    AgentSketch::Nodes::AgentDefinition.new(
      name:          :test_agent,
      model:         "gpt-4o",
      provider:      nil,
      role:          "Test agent",
      goal:          nil,
      persona:       nil,
      temperature:   0.7,
      max_tokens:    nil,
      tools:         [],
      memory:        AgentSketch::Nodes::MemorySpec.new(strategy: :none, options: {}),
      retry_policy:  AgentSketch::Nodes::DEFAULT_RETRY,
      timeout:       nil,
      fallback:      nil,
      output_format: :text,
      output_schema: nil
    )
  end

  let(:mock_response) do
    double("Response",
      content: "Test response content",
      usage:   double("Usage", total_tokens: 100, input_tokens: 60, output_tokens: 40)
    )
  end

  let(:mock_chat) do
    double("Chat").tap do |c|
      allow(c).to receive(:with_instructions).and_return(c)
      allow(c).to receive(:with_tools).and_return(c)
      allow(c).to receive(:params).and_return(c)
      allow(c).to receive(:ask).and_return(mock_response)
    end
  end

  subject(:step) { described_class.new(agent_def, []) }

  before do
    allow(RubyLLM).to receive(:chat).and_return(mock_chat)
  end

  describe "#id" do
    it "returns the agent name as string" do
      expect(step.id).to eq("test_agent")
    end
  end

  describe "#call" do
    let(:context) do
      double("Context",
        :[]   => nil,
        :key? => false
      ).tap do |c|
        allow(c).to receive(:[]).with(:input).and_return("Hello world")
        allow(c).to receive(:[]).with(:__last_output).and_return(nil)
      end
    end

    it "returns a successful StepResult" do
      result = step.call(context)
      expect(result).to be_a(Aflow::StepResult)
      expect(result.status).to eq(:success)
    end

    it "includes the agent output in the result" do
      result = step.call(context)
      expect(result.output[:__last_output]).to eq("Test response content")
    end

    it "includes token metrics" do
      result = step.call(context)
      expect(result.metrics[:tokens]).to eq(100)
    end

    context "when the LLM raises an error" do
      before do
        allow(mock_chat).to receive(:ask).and_raise(StandardError, "LLM error")
      end

      it "returns an error StepResult" do
        result = step.call(context)
        expect(result.status).to eq(:error)
      end
    end
  end
end
