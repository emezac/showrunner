# frozen_string_literal: true

require "test_helper"

class ProjectsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  def setup
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
    Account.first_or_create!(name: "Showrunner Productions")
    @user = User.first_or_create!(name: "Enrique Director", email: "enrique@showrunner.ai")
    @script_lf = <<~SCRIPT.strip
      SCENE 1
      A miniature foosball player strikes the ball while remaining attached to the metal rod.

      SCENE 2
      The same player and the same ball remain at their fixed scale as the ball reaches the goal.
    SCRIPT
  end

  test "architecture documents the current consistency-first runtime" do
    get architecture_path

    assert_response :success
    assert_select "h1", text: /contract-bound/
    assert_select "#systemArchitectureDiagram", count: 1
    assert_select "#diagram", text: /End-to-end system diagram/
    assert_select "#pipeline .arch-stage", count: 6
    assert_select "#consistency", text: /Visual invariants are hard gates/
    assert_select "#modes", text: /Automatic resolves; Full Control obeys/
    assert_select "#recovery", text: /Durable reference rule/
    assert_includes response.body, ProduceDramaJob::RUNTIME_VERSION
    assert_includes response.body, "CanonicalMediaStore"
    assert_includes response.body, "render_runtime"
  end

  test "creates a project when an LF forecast approves an HTML CRLF screenplay" do
    forecast_input = production_input(prompt: @script_lf, token_budget: 5_000)
    forecast = ProductionTokenPredictor.estimate(input: forecast_input, history_scope: @user.projects)

    assert forecast["overrun_required"]
    assert_difference("Project.count", 1) do
      post projects_path, params: {
        project: project_attributes(prompt: @script_lf.gsub("\n", "\r\n"), token_budget: 5_000),
        pipeline_mode: "agentic",
        adaptation_mode: "faithful",
        token_forecast_digest: forecast["approval_digest"],
        approve_token_overrun: "1"
      }
    end

    project = Project.order(:id).last
    assert_redirected_to project_path(project)
    assert project.direction["production_token_overrun_authorized"]
  end

  test "creates a project without approval after applying the predicted safe budget" do
    initial = ProductionTokenPredictor.estimate(
      input: production_input(prompt: @script_lf, token_budget: 5_000),
      history_scope: @user.projects
    )
    safe_budget = initial["recommended_budget"]
    safe_forecast = ProductionTokenPredictor.estimate(
      input: production_input(prompt: @script_lf, token_budget: safe_budget),
      history_scope: @user.projects
    )

    refute safe_forecast["overrun_required"]
    assert_difference("Project.count", 1) do
      post projects_path, params: {
        project: project_attributes(prompt: @script_lf, token_budget: safe_budget),
        pipeline_mode: "agentic",
        adaptation_mode: "faithful"
      }
    end

    assert_redirected_to project_path(Project.order(:id).last)
  end

  test "full control rejects unresolved auto fields before planning" do
    assert_no_difference("Project.count") do
      post projects_path, params: {
        project: project_attributes(prompt: @script_lf, token_budget: 500_000),
        pipeline_mode: "control",
        adaptation_mode: "faithful",
        genre: "sci_fi"
      }
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "Sound direction must be selected in Full Control mode"
  end

  test "a consumed visual override cannot silently bypass a failed keyframe" do
    screenplay = {
      "title" => "QA recovery",
      "scenes" => [{
        "id" => "scene_01", "heading" => "INT. TABLE - DAY", "action" => "The miniature remains on its rod.",
        "shots" => [{
          "id" => "1.4", "duration" => 5, "visual_prompt" => "The miniature and ball share a calibrated scale.",
          "image_url" => "https://example.test/failed.png"
        }]
      }]
    }
    report = {
      "ready_for_render" => true,
      "structural_score" => 90,
      "critical_count" => 1,
      "issues" => [{ "severity" => "critical", "code" => "visual_consistency_failed", "message" => "Scale mismatch" }],
      "visual_metrics" => { "status" => "measured", "average_score" => 84.2, "failed_shot_ids" => ["1.4"] },
      "visual_qa_override" => { "applied" => true }
    }
    project = @user.projects.create!(
      prompt: @script_lf, status: "failed", dry_run: false, token_budget: 20_000,
      tokens_remaining: 5_000, manifest: { "screenplay" => screenplay, "consistency_report" => report }
    )

    assert_no_enqueued_jobs do
      post render_video_project_path(project)
    end

    assert_redirected_to project_path(project)
    assert_equal "failed", project.reload.status
    assert_equal "Consistency gate failed. Regenerate failed frames, retry visual or final-video QA, repair failed clips, or explicitly accept visual-QA risk.", flash[:alert]
  end

  test "failed keyframes have a direct recovery control" do
    screenplay = {
      "title" => "QA recovery",
      "scenes" => [{
        "id" => "scene_01", "heading" => "INT. TABLE - DAY", "action" => "The miniature remains on its rod.",
        "shots" => [{
          "id" => "1.4", "duration" => 5, "visual_prompt" => "The miniature and ball share a calibrated scale.",
          "image_url" => "https://example.test/failed.png"
        }]
      }]
    }
    report = {
      "ready_for_render" => false,
      "structural_score" => 90,
      "critical_count" => 1,
      "issues" => [{ "severity" => "critical", "code" => "visual_consistency_failed", "message" => "Scale mismatch" }],
      "visual_metrics" => { "status" => "measured", "average_score" => 84.2, "failed_shot_ids" => ["1.4"] }
    }
    project = @user.projects.create!(
      prompt: @script_lf, status: "failed", dry_run: false,
      manifest: { "screenplay" => screenplay, "consistency_report" => report }
    )

    get project_path(project)

    assert_response :success
    assert_select "#gateStateLabel", text: "FAILED"
    assert_select "button[data-failed-keyframe-action='1.4']", text: /Fix failed keyframe 1.4/
    assert_select "#rerunVisualQaBtn", text: /Retry Visual QA Only/
    assert_select "form[action='#{render_video_project_path(project)}'] button", text: /Generate Video and Accept Visual Risk/
    assert_includes response.body, "failedShotIds: [\"1.4\"]"
  end

  test "a failed render explains whether video synthesis ever started" do
    project = @user.projects.create!(
      prompt: @script_lf,
      status: "failed",
      dry_run: false,
      manifest: {
        "render_runtime" => {
          "state" => "failed",
          "outcome" => "blocked_before_video_synthesis_by_storyboard_visual_qa",
          "error" => "Consistency preflight rejected the storyboard"
        }
      }
    )

    get project_path(project)

    assert_response :success
    assert_select "#lastRenderOutcome", text: /Consistency preflight rejected the storyboard/
    assert_select "#lastRenderOutcome", text: /No video synthesis was started/
  end

  test "an explicit video-risk authorization is propagated to the next render" do
    screenplay = {
      "scenes" => [{ "shots" => [{ "id" => "1.1", "image_url" => "https://example.test/approved.png" }] }]
    }
    report = {
      "ready_for_render" => true,
      "critical_count" => 0,
      "issues" => [],
      "visual_metrics" => { "status" => "measured", "average_score" => 96, "failed_shot_ids" => [] }
    }
    project = @user.projects.create!(
      prompt: @script_lf, status: "failed", dry_run: false, token_budget: 20_000,
      tokens_remaining: 5_000,
      manifest: {
        "screenplay" => screenplay,
        "consistency_report" => report,
        "video_consistency_report" => {
          "status" => "measured", "average_score" => 90.2, "failed_shot_ids" => ["1.4", "6.1"]
        }
      }
    )

    get project_path(project)
    assert_response :success
    assert_select "#gateStateLabel", text: "FAILED"
    assert_select "#videoVisualScore", text: /90.2\/100/
    assert_select "#failedVideoActions", text: /1.4, 6.1/
    assert_select "form[action='#{render_video_project_path(project)}'] button", text: /Re-render Video and Accept Visual Risk/

    assert_enqueued_with(job: ProduceDramaJob, args: [project.id]) do
      post render_video_project_path(project), params: { allow_visual_qa_override: "true" }
    end

    authorization = project.reload.manifest["visual_qa_override"]
    assert_equal ConsistencyOverridePolicy::RENDER_SCOPE, authorization["scope"]
    assert_equal "rendering", project.status
  end

  test "targeted final-video recovery reuses the approved storyboard without a risk override" do
    screenplay = {
      "scenes" => [{ "shots" => [{ "id" => "1.1", "image_url" => "https://example.test/approved.png" }] }]
    }
    project = @user.projects.create!(
      prompt: @script_lf, status: "failed", dry_run: false, token_budget: 20_000,
      tokens_remaining: 5_000,
      manifest: {
        "screenplay" => screenplay,
        "consistency_report" => {
          "ready_for_render" => true, "critical_count" => 0, "issues" => [],
          "visual_metrics" => { "status" => "measured", "average_score" => 96, "failed_shot_ids" => [] }
        },
        "video_consistency_report" => {
          "status" => "measured", "average_score" => 82,
          "failed_shot_ids" => ["1.1"],
          "automatic_repairs_attempted" => [],
          "repair_policy" => "disabled_by_full_control"
        }
      }
    )

    get project_path(project)
    assert_response :success
    assert_select "#retryFinalVideoQaBtn", text: /Repair Failed Clips/
    assert_includes response.body, "no automatic clip repair was run"

    assert_enqueued_with(job: ProduceDramaJob, args: [project.id]) do
      post render_video_project_path(project), params: { retry_video_qa: "true" }
    end

    project.reload
    assert_equal "rendering", project.status
    assert_nil project.manifest["visual_qa_override"]
  end

  test "an existing failed-QA cut can be accepted without another render or charge" do
    screenplay = {
      "scenes" => [{
        "shots" => [{
          "id" => "1.1", "duration" => 5,
          "image_url" => "https://example.test/approved.png",
          "visual_prompt" => "The canonical miniature remains fixed to its rod."
        }]
      }]
    }
    manifest = {
      "screenplay" => screenplay,
      "assets" => {},
      "consistency_report" => {
        "ready_for_render" => true, "critical_count" => 0, "issues" => [],
        "visual_metrics" => { "status" => "measured", "average_score" => 96, "failed_shot_ids" => [] }
      },
      "video_consistency_report" => {
        "status" => "measured", "average_score" => 82, "failed_shot_ids" => ["1.1"]
      }
    }
    project = @user.projects.create!(
      prompt: @script_lf, status: "failed", dry_run: false, token_budget: 20_000,
      tokens_remaining: 0, tokens_used: 20_000, video_credits_used: 9, manifest: manifest
    )
    output = Rails.root.join("public", "dramas", "drama_#{project.id}.mp4")
    FileUtils.mkdir_p(output.dirname)
    File.binwrite(output, "recoverable-video-cut")
    manifest["pending_video_review"] = {
      "available" => true,
      "url" => "/dramas/drama_#{project.id}.mp4",
      "video_sha256" => Digest::SHA256.file(output).hexdigest,
      "render_contract_digest" => ConsistencyOverridePolicy.render_contract_digest(manifest),
      "failed_shot_ids" => ["1.1"]
    }
    project.update!(manifest: manifest)

    assert_no_enqueued_jobs do
      post render_video_project_path(project), params: { allow_visual_qa_override: "true" }
    end

    project.reload
    assert_equal "completed", project.status
    assert_equal "/dramas/drama_#{project.id}.mp4", project.final_video_url
    assert_equal 9, project.video_credits_used
    assert_equal 20_000, project.tokens_used
    assert project.manifest.dig("video_consistency_report", "override_applied")
    assert_nil project.manifest["pending_video_review"]
  ensure
    FileUtils.rm_f(output) if output
  end

  test "character regeneration persists the new canonical reference through contract rebuild" do
    prompt = <<~PROMPT
      CHARACTER: A tiny scratched red plastic foosball figurine, permanently mounted on a steel control rod,
      the same height as all peer foosball figures. It is sentient but can only rotate or slide along its rod.

      SCENE 1
      The figurine rotates toward the ball without detaching from the rod.
    PROMPT
    screenplay = {
      "title" => "Canonical recovery",
      "source_profiles" => { "characters" => "A tiny scratched red plastic foosball figurine permanently mounted on a steel control rod." },
      "scenes" => [{
        "id" => "scene_01", "heading" => "INT. FOOSBALL TABLE - DAY", "action" => "The figurine rotates toward the ball.",
        "shots" => [{ "id" => "1.1", "duration" => 5, "visual_prompt" => "The tiny red figurine rotates on its rod." }]
      }]
    }
    project = @user.projects.create!(
      prompt: prompt, status: "awaiting_storyboard_approval", dry_run: false,
      token_budget: 20_000, tokens_used: 20_000, tokens_remaining: 0,
      manifest: {
        "screenplay" => screenplay,
        "assets" => {
          "characters" => [{
            "id" => "char_1", "name" => "PROTAGONIST", "entity_type" => "toy_or_figurine",
            "physical_description" => "A tiny scratched red plastic foosball figurine fixed to a steel rod.",
            "visual_prompt" => "CANONICAL NARRATIVE CHARACTER REFERENCE — GENERATION SAFE. MINIATURE CLASS LOCK: same height as peer figurines.",
            "image_url" => nil, "reference_images" => []
          }],
          "props" => [], "locations" => []
        }
      }
    )
    generated_url = "https://example.test/new-canonical-character.png"
    result = OpenStruct.new(succeeded?: true, image_url: generated_url)
    fake_client = Object.new
    fake_client.define_singleton_method(:submit_with_retries) do |prompt:, mode:, reference_image_urls: nil, **|
      raise "expected narrative reference generation" unless mode == :t2i && prompt.include?("GENERATION SAFE")
      result
    end

    original_constructor = HappyHorseClient.method(:new)
    HappyHorseClient.define_singleton_method(:new) { |*args, **kwargs| fake_client }
    begin
      post regenerate_asset_image_project_path(project), params: {
        asset_id: "char_1", asset_type: "characters", allow_token_overrun: "true"
      }, as: :json
    ensure
      HappyHorseClient.define_singleton_method(:new, original_constructor)
    end

    assert_response :success
    payload = response.parsed_body
    assert_equal "success", payload["status"]
    assert_equal generated_url, payload["image_url"]
    assert_operator payload.dig("consistency", "structural_score"), :>, 0

    project.reload
    character = project.manifest.dig("assets", "characters", 0)
    assert_equal generated_url, character["image_url"]
    assert_equal generated_url, character["reference_images"].first
    assert_includes project.manifest.dig("production_bible", "entities", 0, "reference_images"), generated_url
    refute_includes Array(project.manifest.dig("consistency_report", "issues")).map { |issue| issue["code"] }, "missing_reference"
    assert_equal 1, project.video_credits_used
  end

  test "exhausted character assets expose an inline extra-token recovery action" do
    project = @user.projects.create!(
      prompt: @script_lf, status: "awaiting_storyboard_approval", dry_run: false,
      token_budget: 20_000, tokens_used: 20_000, tokens_remaining: 0,
      manifest: {
        "screenplay" => { "scenes" => [] },
        "assets" => {
          "characters" => [{
            "id" => "char_1", "name" => "PROTAGONIST",
            "physical_description" => "A small scratched red plastic foosball figurine attached to a rod.",
            "visual_prompt" => "Clean canonical narrative reference", "image_url" => nil
          }]
        },
        "consistency_report" => {
          "ready_for_render" => false, "critical_count" => 1,
          "issues" => [{ "severity" => "critical", "code" => "missing_reference", "message" => "CHARACTER_1 has no remote canonical reference" }],
          "visual_metrics" => { "status" => "not_measured" }
        }
      }
    )

    get project_path(project)

    assert_response :success
    assert_select "#empty-char-char_1", text: /Canonical frame required/
    assert_select "#asset-status-char-char_1[role='status']"
    assert_includes response.body, "Allow Extra Tokens & Regenerate"
    assert_includes response.body, "requestAssetTokenAuthorization"
  end

  private

  def production_input(prompt:, token_budget:)
    input = {
      prompt: prompt,
      duration: 45,
      resolution: "720P",
      dry_run: false,
      token_budget: token_budget,
      pipeline_mode: "agentic",
      adaptation_mode: "faithful"
    }
    policy = ProductionModePolicy.resolve(input: input, prompt: prompt)
    input.merge(policy["direction"].slice(
      "pipeline_mode", "adaptation_mode", "genre", "camera_style", "color_grade",
      "music_style", "voice_style", "max_scenes"
    ))
  end

  def project_attributes(prompt:, token_budget:)
    {
      prompt: prompt,
      duration: 45,
      resolution: "720P",
      dry_run: "0",
      token_budget: token_budget
    }
  end
end
