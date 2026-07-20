# frozen_string_literal: true

require "spec_helper"

RSpec.describe AgentSketch::Runner do
  let(:plan) do
    AgentSketch::Builder.build do
      agent :echo_agent do
        model "gpt-4o"
        role  "Echo agent"
      end
      workflow { echo_agent }
    end
  end

  describe "#run with dry_run: true" do
    subject(:result) do
      described_class.new(plan, dry_run: true).run("test input")
    end

    it "returns a RunResult" do
      expect(result).to be_a(AgentSketch::RunResult)
    end

    it "is marked as successful" do
      expect(result.success?).to be true
    end

    it "returns DAG preview as output" do
      expect(result.output).to include("AgentSketch Workflow DAG")
    end

    it "does not call any LLM" do
      expect(RubyLLM).not_to receive(:chat)
      result
    end
  end

  describe "RunResult" do
    let(:mock_trace) do
      double("Trace",
        success?:          true,
        total_duration_ms: 1200,
        events:            []
      )
    end

    subject(:run_result) do
      AgentSketch::RunResult.new(
        output:  "Final output",
        trace:   mock_trace,
        cost:    { tokens: { prompt: 100, completion: 50, total: 150 }, usd: 0.002 },
        success: true,
        errors:  []
      )
    end

    it "reports success correctly" do
      expect(run_result.success?).to be true
      expect(run_result.failure?).to be false
    end

    it "reports no errors" do
      expect(run_result.errors?).to be false
    end

    it "formats cost summary" do
      expect(run_result.cost_summary).to include("150 tokens")
      expect(run_result.cost_summary).to include("$")
    end

    it "converts to string" do
      expect(run_result.to_s).to eq("Final output")
    end
  end
end
