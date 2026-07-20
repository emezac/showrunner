# frozen_string_literal: true

require "spec_helper"

RSpec.describe AgentSketch::Tools::Calculator do
  subject(:calc) { described_class.new }

  describe "#execute" do
    it "evaluates simple arithmetic" do
      expect(calc.execute(expression: "2 + 2")).to eq("4")
    end

    it "handles multiplication" do
      expect(calc.execute(expression: "3 * 7")).to eq("21")
    end

    it "handles division" do
      expect(calc.execute(expression: "10 / 2")).to eq("5")
    end

    it "handles parentheses" do
      expect(calc.execute(expression: "2 * (3 + 4)")).to eq("14")
    end

    it "handles power operator" do
      expect(calc.execute(expression: "2^10")).to eq("1024")
    end

    it "returns error for division by zero" do
      expect(calc.execute(expression: "1 / 0")).to include("Error")
    end

    it "rejects non-math expressions" do
      result = calc.execute(expression: "system('rm -rf /')")
      expect(result).to include("no permitida")
    end
  end
end

RSpec.describe AgentSketch::Tools::TextEditor do
  subject(:editor) { described_class.new }

  describe "#execute" do
    it "writes content to buffer" do
      result = editor.execute(action: "write", content: "Hello world")
      expect(result).to include("11 caracteres")
    end

    it "reads back the buffer" do
      editor.execute(action: "write", content: "Test content")
      expect(editor.execute(action: "read")).to eq("Test content")
    end

    it "appends to buffer" do
      editor.execute(action: "write", content: "First")
      editor.execute(action: "append", content: "Second")
      expect(editor.execute(action: "read")).to include("First")
      expect(editor.execute(action: "read")).to include("Second")
    end

    it "replaces text in buffer" do
      editor.execute(action: "write", content: "Hello world")
      editor.execute(action: "replace", content: "Ruby", target: "world")
      expect(editor.execute(action: "read")).to eq("Hello Ruby")
    end

    it "clears the buffer" do
      editor.execute(action: "write", content: "Something")
      editor.execute(action: "clear")
      expect(editor.execute(action: "read")).to include("vacío")
    end

    it "returns error for unknown action" do
      result = editor.execute(action: "fly")
      expect(result).to include("Acción desconocida")
    end
  end
end
