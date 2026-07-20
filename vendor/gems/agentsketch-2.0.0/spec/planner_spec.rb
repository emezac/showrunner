# frozen_string_literal: true

require "spec_helper"

RSpec.describe AgentSketch::Planner do
  def build_plan(&block)
    AgentSketch::Builder.build(&block)
  end

  describe "#validate!" do
    context "with an unknown agent referenced in workflow" do
      it "raises UnknownAgentError" do
        plan = build_plan do
          agent(:known) { model "gpt-4o"; role "Known" }
          workflow { known >> unknown_agent }
        end

        expect do
          described_class.new(plan).build_flow
        end.to raise_error(AgentSketch::UnknownAgentError, /unknown_agent/)
      end
    end

    context "with :image_analyzer on a non-vision model" do
      it "raises ModelVisionError" do
        plan = build_plan do
          agent :analyst do
            model "gpt-4o-mini"
            role  "Analista"
            tools [:image_analyzer]
          end
          workflow { analyst }
        end

        expect do
          described_class.new(plan).build_flow
        end.to raise_error(AgentSketch::ModelVisionError, /image_analyzer/)
      end
    end

    context "with :rag without vector store configured" do
      it "raises RagConfigError" do
        AgentSketch.reset_configuration!

        plan = build_plan do
          agent :retriever do
            model "gpt-4o"
            role  "Retriever"
            tools [:rag]
          end
          workflow { retriever }
        end

        expect do
          described_class.new(plan).build_flow
        end.to raise_error(AgentSketch::RagConfigError)
      end
    end
  end

  describe "#dag_preview" do
    subject(:preview) do
      plan = build_plan do
        agent(:a) { model "gpt-4o"; role "Agente A" }
        agent(:b) { model "claude-sonnet-4-6"; role "Agente B" }
        workflow { a >> b }
      end
      described_class.new(plan).dag_preview
    end

    it "includes agent names" do
      expect(preview).to include("a")
      expect(preview).to include("b")
    end

    it "includes model names" do
      expect(preview).to include("gpt-4o")
    end

    it "draws box borders" do
      expect(preview).to include("┌")
      expect(preview).to include("└")
    end
  end
end
