# frozen_string_literal: true

require "test_helper"
require_relative "../../lib/showrunner"

class ShowrunnerEngineSelectionTest < ActiveSupport::TestCase
  test "restores an approved faithful selection without calling qwen" do
    engine = ShowrunnerEngine.new(
      config: { prompt: "A toy returns home", token_budget: 5_000, seed: 42, adaptation_mode: "faithful" }
    )

    engine.restore_selection!(
      "base_story_id" => "faithful_prompt",
      "preserved_genes" => ["custom_prompt"],
      "domain" => "foosball",
      "tone" => "epic",
      "protagonist_bible" => "A worn plastic foosball player",
      "cargo_bible" => "The restored figurine"
    )

    assert_equal :foosball, engine.selection.domain
    assert_equal :epic, engine.selection.tone
    assert_equal "faithful_prompt", engine.selection.base_story[:id]
    assert_equal "A worn plastic foosball player", engine.selection.protagonist_bible
    assert_empty engine.token_ledger[:calls]
    assert_equal 0, engine.token_ledger[:tokens_used]
  end
end
