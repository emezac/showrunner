# frozen_string_literal: true

require "spec_helper"

RSpec.describe AgentSketch::Builder do
  describe ".build" do
    context "with a valid DSL block" do
      subject(:plan) do
        described_class.build do
          agent :researcher do
            model  "gpt-4o"
            role   "Investigador"
            tools  [:web_search]
            memory :sliding_window, size: 5
            retry_policy  max: 2, backoff: :exponential
            timeout 60
          end

          agent :writer do
            model         "claude-sonnet-4-6"
            role          "Escritor"
            output_format :markdown
          end

          workflow { researcher >> writer }
        end
      end

      it "returns an AgentPlan" do
        expect(plan).to be_a(AgentSketch::AgentPlan)
      end

      it "captures both agents" do
        expect(plan.agents.keys).to contain_exactly(:researcher, :writer)
      end

      it "stores model correctly" do
        expect(plan.agents[:researcher].model).to eq("gpt-4o")
      end

      it "stores tools as ToolSpec objects" do
        tools = plan.agents[:researcher].tools
        expect(tools.size).to eq(1)
        expect(tools.first.name).to eq(:web_search)
      end

      it "stores memory spec" do
        mem = plan.agents[:researcher].memory
        expect(mem.strategy).to eq(:sliding_window)
        expect(mem.options[:size]).to eq(5)
      end

      it "stores retry policy" do
        retry_policy = plan.agents[:researcher].retry_policy
        expect(retry_policy.max).to eq(2)
        expect(retry_policy.backoff).to eq(:exponential)
      end

      it "stores timeout" do
        expect(plan.agents[:researcher].timeout).to eq(60)
      end

      it "builds a SequentialNode workflow" do
        expect(plan.workflow).to be_a(AgentSketch::Nodes::SequentialNode)
      end

      it "has the correct step order" do
        steps = plan.workflow.steps
        ids   = steps.map { |s| s.is_a?(AgentSketch::Nodes::AgentNode) ? s.agent_id : s }
        expect(ids).to include(:researcher, :writer)
      end
    end

    context "without a workflow" do
      it "raises PlanError" do
        expect do
          described_class.build do
            agent(:x) { model "gpt-4o"; role "X" }
          end
        end.to raise_error(AgentSketch::PlanError, /workflow/)
      end
    end

    context "parallel workflow" do
      subject(:plan) do
        described_class.build do
          agent(:a) { model "gpt-4o"; role "A" }
          agent(:b) { model "gpt-4o"; role "B" }
          agent(:c) { model "gpt-4o"; role "C" }
          workflow { a || b || c }
        end
      end

      it "builds a ParallelNode" do
        expect(plan.workflow).to be_a(AgentSketch::Nodes::ParallelNode)
        expect(plan.workflow.branches.size).to eq(3)
      end
    end
  end
end
