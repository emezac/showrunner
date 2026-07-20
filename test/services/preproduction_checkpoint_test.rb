# frozen_string_literal: true

require "test_helper"

class PreproductionCheckpointTest < ActiveSupport::TestCase
  def setup
    Account.first_or_create!(name: "Checkpoint Test Account")
    @user = User.first_or_create!(name: "Checkpoint Producer", email: "checkpoint@showrunner.test")
    @project = @user.projects.create!(
      prompt: "A source-locked human character crosses a workshop.",
      status: "planning",
      token_budget: 20_000,
      tokens_used: 0,
      tokens_remaining: 20_000,
      video_credits_used: 0,
      resolution: "720P",
      duration: 30,
      seed: 123,
      dry_run: false,
      direction: { "pipeline_mode" => "control", "genre" => "drama" },
      manifest: {}
    )
  end

  test "persists paid stage output and budget atomically" do
    saved = PreproductionCheckpoint.persist!(
      project_id: @project.id,
      stage: "screenplay",
      ledger: {
        tokens_used: 1_250, tokens_remaining: 18_750,
        video_credits_used: 0, calls: [{ stage: "screenplay" }]
      },
      data: { "screenplay" => { "title" => "Checkpointed" } }
    )

    assert_equal "screenplay", PreproductionCheckpoint.stage_for(saved)
    assert_equal "Checkpointed", saved.manifest.dig("screenplay", "title")
    assert_equal 1_250, saved.tokens_used
    assert_equal 18_750, saved.tokens_remaining
    assert_equal "screenplay", saved.manifest.dig("budget_ledger", "calls", 0, "stage")
  end

  test "does not resume a checkpoint after the production contract changes" do
    saved = PreproductionCheckpoint.persist!(
      project_id: @project.id,
      stage: "assets",
      ledger: { tokens_used: 2_000, tokens_remaining: 18_000, video_credits_used: 2 },
      data: { "assets" => { "characters" => [] } }
    )
    assert_equal "assets", PreproductionCheckpoint.stage_for(saved)

    saved.update!(direction: saved.direction.merge("genre" => "science_fiction"))
    assert_nil PreproductionCheckpoint.stage_for(saved)
  end

  test "a deleted project is a non-retryable cooperative cancellation signal" do
    id = @project.id
    @project.destroy!

    assert_raises(ActiveRecord::RecordNotFound) do
      PreproductionCheckpoint.active!(id)
    end
  end
end
