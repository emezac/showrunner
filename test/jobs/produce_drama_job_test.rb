# frozen_string_literal: true

require "test_helper"

class ProduceDramaJobTest < ActiveSupport::TestCase
  def setup
    Account.first_or_create!(name: "Render Claim Test Account")
    @user = User.first_or_create!(name: "Render Claim Producer", email: "render-claim@showrunner.test")
    @project = @user.projects.create!(
      prompt: "A stable production contract.",
      status: "rendering",
      token_budget: 20_000,
      tokens_used: 1_000,
      tokens_remaining: 19_000,
      video_credits_used: 0,
      resolution: "720P",
      duration: 30,
      seed: 321,
      dry_run: true,
      direction: { "pipeline_mode" => "control" },
      manifest: {}
    )
  end

  test "only one job can claim the same active render" do
    first_job = ProduceDramaJob.new
    second_job = ProduceDramaJob.new

    claimed = first_job.send(:claim_render!, @project.id)

    assert_equal @project.id, claimed.id
    assert_equal first_job.job_id, claimed.manifest.dig("render_runtime", "job_id")
    assert_nil second_job.send(:claim_render!, @project.id)
  end

  test "stale jobs cannot reopen a finished project" do
    @project.update!(status: "completed")

    assert_nil ProduceDramaJob.new.send(:claim_render!, @project.id)
    assert_equal "completed", @project.reload.status
  end

  test "a pre-video failure records its outcome and settles only the usage already consumed" do
    ledger = {
      tokens_used: 250,
      tokens_remaining: 18_750,
      video_credits_used: 2,
      allow_token_overrun: true,
      calls: [{ stage: "visual_consistency", tokens: 250 }]
    }

    ProduceDramaJob.new.send(
      :fail_render!,
      @project,
      manifest: @project.manifest,
      message: "Storyboard visual QA rejected one keyframe",
      outcome: "blocked_before_video_synthesis_by_storyboard_visual_qa",
      ledger: ledger
    )

    @project.reload
    assert_equal "failed", @project.status
    assert_equal 1_250, @project.tokens_used
    assert_equal 18_750, @project.tokens_remaining
    assert_equal 2, @project.video_credits_used
    assert_equal "failed", @project.manifest.dig("render_runtime", "state")
    assert_equal "blocked_before_video_synthesis_by_storyboard_visual_qa", @project.manifest.dig("render_runtime", "outcome")
    assert_equal "Storyboard visual QA rejected one keyframe", @project.manifest.dig("render_runtime", "error")
    assert_nil @project.manifest.dig("last_render_ledger", "allow_token_overrun")
  end
end
