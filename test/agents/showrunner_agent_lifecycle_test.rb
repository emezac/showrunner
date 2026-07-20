# frozen_string_literal: true

require "test_helper"

class ShowrunnerAgentLifecycleTest < ActiveSupport::TestCase
  def setup
    Account.first_or_create!(name: "Agent Lifecycle Test Account")
    @user = User.first_or_create!(name: "Agent Lifecycle Producer", email: "agent-lifecycle@showrunner.test")
    @project = @user.projects.create!(
      prompt: "A production that must never be charged after cancellation.",
      status: "planning",
      token_budget: 20_000,
      tokens_used: 0,
      tokens_remaining: 20_000,
      video_credits_used: 0,
      resolution: "720P",
      duration: 30,
      seed: 456,
      dry_run: false,
      direction: { "pipeline_mode" => "control" },
      manifest: {}
    )
    @agent = ShowrunnerAgent.new(user: @user)
  end

  test "a stale duplicate planning job exits before any provider call" do
    @project.update!(status: "awaiting_storyboard_approval")

    assert_equal true, @agent.call(@project)
    assert_equal 0, @project.reload.tokens_used
    assert_equal({}, @project.manifest)
  end

  test "a deleted project cancels a worker holding a stale in-memory object" do
    stale_project = @project
    @project.destroy!

    assert_equal true, @agent.call(stale_project)
    assert_nil Project.find_by(id: stale_project.id)
  end
end
