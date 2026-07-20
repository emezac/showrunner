# frozen_string_literal: true

require "minitest/autorun"
require "active_support/all"
require "active_record"
require "ostruct"

require_relative "../../app/services/production_bible"
require_relative "../../app/services/continuity_planner"
require_relative "../../app/services/consistency_evaluator"
require_relative "../../app/services/asset_profiler"
require_relative "../../app/services/source_profile_extractor"
require_relative "../../app/services/scale_contract_resolver"
require_relative "../../app/services/script_consistency_validator"
require_relative "../../app/services/continuity_plate_planner"
require_relative "../../app/services/consistency_override_policy"
require_relative "../../app/services/production_token_predictor"
require_relative "../../app/services/production_mode_policy"
require_relative "../../app/services/audio_director"
require_relative "../../app/services/storyboard_regenerator"
require_relative "../../app/services/visual_consistency_evaluator"
require_relative "../../lib/showrunner"
require_relative "../../app/services/video_consistency_evaluator"

class ConsistencyPipelineTest < Minitest::Test
  RegenerationProject = Struct.new(
    :prompt, :duration, :resolution, :token_budget, :seed, :dry_run,
    :tokens_used, :tokens_remaining, :video_credits_used, :direction,
    keyword_init: true
  ) do
    def dry_run? = !!dry_run
  end

  class PassingVisualEvaluator
    def self.evaluate(screenplay:, **)
      shots = Array(screenplay["scenes"]).flat_map { |scene| Array(scene["shots"]) }
      {
        "status" => "measured", "average_score" => 100,
        "failed_shot_ids" => [],
        "shots" => shots.map { |shot| { "shot_id" => shot["id"], "pass" => true, "overall_score" => 100 } }
      }
    end
  end

  class FakeVideoClient
    attr_reader :inputs, :logger, :poll_calls

    def initialize(source_clip, failed_poll_task_ids: [])
      @source_clip = source_clip
      @logger = HappyHorse::NullLogger.new
      @poll_calls = []
      @failed_poll_task_ids = failed_poll_task_ids.map(&:to_s)
    end

    def submit_batch(shots, max_concurrent:)
      @inputs = shots
      shots.each do |shot|
        result = HappyHorse::PollResult.new(task_id: "task-#{shot[:id]}", status: "SUCCEEDED", video_url: "https://example.test/video.mp4", raw: {})
        yield(shot, result)
      end
    end

    def download(_url, to:)
      FileUtils.cp(@source_clip, to)
    end

    def poll_once(task_id)
      @poll_calls << task_id
      if @failed_poll_task_ids.include?(task_id.to_s)
        return HappyHorse::PollResult.new(
          task_id: task_id, status: "FAILED", video_url: nil, raw: {}
        )
      end

      HappyHorse::PollResult.new(
        task_id: task_id, status: "SUCCEEDED",
        video_url: "https://example.test/restored.mp4", raw: {}
      )
    end
  end

  class FakeImageClient
    Result = Struct.new(:image_url) do
      def succeeded? = true
    end

    attr_reader :calls

    def initialize
      @calls = []
    end

    def submit_with_retries(**args)
      @calls << args
      Result.new("https://example.test/continuity-#{@calls.size}.png")
    end
  end

  def setup
    @screenplay = {
      "scenes" => [
        {
          "heading" => "INT. WORKSHOP - DAY",
          "action" => "Mara rolls the amber sphere across the steel workbench.",
          "dialogue" => [{ "character" => "MARA", "line" => "It is stable." }],
          "shots" => [
            {
              "id" => "1.1",
              "visual_prompt" => "Mara pushes the amber sphere from left to right",
              "camera" => "close_up",
              "duration" => 3
            },
            {
              "id" => "1.2",
              "visual_prompt" => "The amber sphere stops beside Mara's hand",
              "camera" => "medium",
              "duration" => 3
            }
          ]
        }
      ]
    }
    @assets = {
      "characters" => [
        {
          "id" => "char_1",
          "name" => "Mara",
          "entity_type" => "human",
          "physical_description" => "32-year-old woman, oval face, brown eyes, black bob haircut",
          "wardrobe" => "navy mechanic coveralls with a silver name patch",
          "immutable_traits" => ["oval face", "black bob haircut", "silver name patch"],
          "scale_reference" => "170 cm tall",
          "image_url" => "https://example.test/mara.png"
        }
      ],
      "props" => [
        {
          "id" => "prop_1",
          "name" => "amber sphere",
          "description" => "smooth translucent amber sphere",
          "color" => "amber orange",
          "material" => "solid resin",
          "dimensions" => "12 cm diameter",
          "physical_constraints" => ["rigid", "rolls on contact", "does not deform"],
          "scale_reference" => "diameter is 7 percent of Mara's height",
          "image_url" => "https://example.test/sphere.png"
        }
      ],
      "locations" => [
        {
          "id" => "loc_1",
          "name" => "workshop",
          "description" => "compact steel workshop",
          "lighting" => "soft daylight",
          "image_url" => "https://example.test/workshop.png"
        }
      ],
      "world_rules" => ["the sphere only moves after visible contact"]
    }
  end

  def test_compiles_generic_human_prop_and_physics_contract
    bible = ProductionBible.compile(screenplay: @screenplay, assets: @assets, original_prompt: "A workshop drama")

    assert_equal %w[CHARACTER_1 PROP_1 LOCATION_1], bible["entities"].map { |entity| entity["id"] }
    assert_equal "human", bible["entities"].first["type"]
    assert_includes bible["entities"][1]["canonical_descriptor"], "12 cm diameter"
    assert_includes bible["global_invariants"], "the sphere only moves after visible contact"
  end

  def test_plans_cross_shot_state_and_selects_keyframe_for_prop_action
    bible = ProductionBible.compile(screenplay: @screenplay, assets: @assets)
    ContinuityPlanner.plan!(@screenplay, bible)
    first, second = @screenplay["scenes"].first["shots"]

    assert_equal %w[CHARACTER_1 PROP_1 LOCATION_1], first.dig("continuity", "required_entity_ids")
    assert_equal "keyframe_i2v", first.dig("continuity", "render_strategy")
    assert_equal "1.1", second.dig("continuity", "continues_from")
    assert_includes second.dig("continuity", "carry_forward_entity_ids"), "PROP_1"
  end

  def test_enforcer_injects_canon_scale_physics_and_generic_negatives
    bible = ProductionBible.compile(screenplay: @screenplay, assets: @assets)
    ContinuityPlanner.plan!(@screenplay, bible)
    selection = OpenStruct.new(domain: :workshop)

    ConsistencyEnforcer.apply!(@screenplay, selection, @assets, production_bible: bible)
    shot = @screenplay["scenes"].first["shots"].first

    assert_includes shot["visual_prompt"], "CANON LOCK"
    assert_includes shot["visual_prompt"], "12 cm diameter"
    assert_includes shot["visual_prompt"], "PHYSICS LOCK"
    assert_includes shot["negative_prompt"], "identity drift"
    refute_includes shot["negative_prompt"], "ball"
  end

  def test_long_source_cannot_push_canon_or_physics_out_of_prompt_budget
    long_action = ("Mara advances the amber sphere with one visible fingertip contact. " * 40).strip
    @screenplay["scenes"].first["shots"].first["visual_prompt"] = long_action
    @screenplay = ScreenplayPlanner.upgrade!(@screenplay, target_duration: 6)
    StoryboardPromptCompiler.compile!(@screenplay)
    bible = ProductionBible.compile(screenplay: @screenplay, assets: @assets)
    ContinuityPlanner.plan!(@screenplay, bible)

    ConsistencyEnforcer.apply!(@screenplay, OpenStruct.new(domain: :workshop), @assets, production_bible: bible)
    prompt = @screenplay["scenes"].first["shots"].first["visual_prompt"]

    assert_operator prompt.length, :<=, ConsistencyEnforcer::MAX_TOTAL_PROMPT_CHARS
    assert_includes prompt, "CANON LOCK"
    assert_includes prompt, "12 cm diameter"
    assert_includes prompt, "PHYSICS LOCK"
    assert_includes prompt, "rolls on contact"
  end

  def test_preflight_is_ready_when_contract_is_complete
    bible = ProductionBible.compile(screenplay: @screenplay, assets: @assets)
    ContinuityPlanner.plan!(@screenplay, bible)
    @screenplay["scenes"].first["shots"].each { |shot| shot["image_url"] = "https://example.test/#{shot['id']}.png" }

    report = ConsistencyEvaluator.evaluate(
      screenplay: @screenplay,
      production_bible: bible,
      assets: @assets,
      strict_references: true
    )

    assert report["ready_for_render"]
    assert_equal 0, report["critical_count"]
    assert_equal 100, report["structural_score"]
  end

  def test_semantic_gate_rejects_generic_character_and_location_fallbacks
    assets = Marshal.load(Marshal.dump(@assets))
    assets["characters"][0]["physical_description"] = "A key character matching the narrative tone."
    assets["characters"][0]["visual_prompt"] = "Cinematic portrait of PROTAGONIST, rich lighting."
    assets["locations"][0]["description"] = "A high-fidelity spatial environment of The Reveal."
    bible = ProductionBible.compile(
      screenplay: @screenplay,
      assets: assets,
      original_prompt: "Mara is a 32-year-old woman with an oval face, brown eyes, a black bob haircut and navy mechanic coveralls. She rolls a translucent amber resin sphere across a compact steel workshop. The sphere is exactly twelve centimeters wide and never deforms."
    )
    ContinuityPlanner.plan!(@screenplay, bible)

    report = ConsistencyEvaluator.evaluate(screenplay: @screenplay, production_bible: bible, assets: assets)

    refute report["ready_for_render"]
    assert_includes report["issues"].map { |issue| issue["code"] }, "generic_character_profile"
    assert_includes report["issues"].map { |issue| issue["code"] }, "generic_location_profile"
  end

  def test_offline_asset_fallback_is_source_locked_and_does_not_treat_beats_as_locations
    screenplay = {
      "source_profiles" => "A tiny rigid red plastic foosball figurine, scratched face, blue painted jersey, attached to a steel rod.",
      "scenes" => [
        { "heading" => "THE CHALLENGE", "action" => "The figurine faces a white cork foosball on the green table.", "shots" => [{ "id" => "1.1", "visual_prompt" => "The figurine strikes the white cork foosball." }] },
        { "heading" => "THE REVEAL", "action" => "The same figurine strikes the same cork ball.", "shots" => [] }
      ]
    }
    project = OpenStruct.new(dry_run: true, prompt: screenplay["source_profiles"])
    selection = OpenStruct.new(
      protagonist_bible: screenplay["source_profiles"],
      cargo_bible: "a white cork foosball, 3 cm diameter, black pentagon markings"
    )

    assets = AssetProfiler.profile!(screenplay, project, selection: selection)

    assert_equal "toy_or_figurine", assets.dig("characters", 0, "entity_type")
    assert_includes assets.dig("characters", 0, "physical_description"), "red plastic"
    refute_includes assets.dig("characters", 0, "visual_prompt"), "vintage attire"
    assert_equal 1, assets["locations"].size
    assert_equal "Primary story environment", assets.dig("locations", 0, "name")
    assert_equal 1, assets["props"].size
    assert_includes assets.dig("props", 0, "physical_constraints"), "does not deform or change diameter"
    assert_includes assets.dig("props", 0, "behavior_constraints"), "moves only after visible contact or declared force"
    assert assets.dig("profiling_report", "ready")

    bible = ProductionBible.compile(screenplay: screenplay, assets: assets, selection: selection)
    ContinuityPlanner.plan!(screenplay, bible)
    assert_includes screenplay.dig("scenes", 0, "shots", 0, "continuity", "required_entity_ids"), "PROP_1"
  end

  def test_inline_character_profile_stops_before_camera_and_scene_directions
    prompt = <<~TEXT
      CHARACTER: ## Visual Description of the Hero
      A small rigid plastic foosball player with scratched red paint and a worn crest.
      His joints remain stiff and he is the same class as every other table player.

      ## First scene of the teaser
      The low camera makes the small figure appear larger and more imposing than it actually is.
      A 75mm lens pushes toward his face.
    TEXT

    profile = SourceProfileExtractor.character_profile(prompt, name: "PROTAGONIST")

    assert_includes profile, "small rigid plastic foosball player"
    refute profile.start_with?("Visual Description")
    refute_includes profile, "appear larger"
    refute_includes profile, "75mm lens"
  end

  def test_scale_resolver_locks_a_miniature_to_same_class_peers_not_to_ball_measurement
    assets = {
      "characters" => [{
        "id" => "char_1", "name" => "Veteran", "entity_type" => "toy_or_figurine",
        "physical_description" => "small rigid plastic foosball player", "visual_prompt" => "full body reference"
      }],
      "props" => [{
        "id" => "prop_1", "name" => "Foosball table",
        "description" => "Rows of player figures fixed to rods and a 3 cm ball",
        "scale_reference" => "Player figures are approximately 8-10 cm tall. Ball is 3 cm wide."
      }],
      "locations" => []
    }

    result = ScaleContractResolver.apply!(assets, source_prompt: "A veteran foosball figurine returns to the table.")
    rule = assets.dig("characters", 0, "scale_reference")

    assert_includes result["changed_asset_ids"], "char_1"
    assert_includes rule, "8-10 cm"
    refute_includes rule, "canonical height 3 cm"
    assert_includes rule, "never human-sized"
    assert assets.dig("characters", 0, "visual_prompt").start_with?("CANONICAL NARRATIVE CHARACTER REFERENCE")
    assert_includes assets.dig("characters", 0, "visual_prompt"), "no ruler"
    refute_includes assets.dig("characters", 0, "visual_prompt"), "visible ruler"
    assert_includes assets.dig("characters", 0, "scale_calibration_prompt"), "same camera depth"
    assert_includes assets.dig("characters", 0, "scale_calibration_prompt"), "exactly equal pixel height"
    assert_includes assets.dig("characters", 0, "allowed_attached_motion"), "translation along the rod axis"
  end

  def test_clean_miniature_reference_survives_repeated_scale_and_bible_compilation
    reference_url = "https://example.test/canonical-portrait.png"
    assets = {
      "characters" => [{
        "id" => "char_1", "name" => "Veteran", "entity_type" => "toy_or_figurine",
        "physical_description" => "A scratched red plastic foosball figurine fixed to a steel rod.",
        "visual_prompt" => "A clean full-body narrative portrait of the foosball figurine.",
        "image_url" => reference_url, "reference_images" => [reference_url]
      }],
      "props" => [], "locations" => []
    }

    2.times { ScaleContractResolver.apply!(assets, source_prompt: "A miniature foosball player comes alive.") }
    bible = ProductionBible.compile(
      screenplay: @screenplay,
      assets: assets,
      original_prompt: "A miniature foosball player comes alive."
    )

    assert_equal reference_url, assets.dig("characters", 0, "image_url")
    assert_equal [reference_url], assets.dig("characters", 0, "reference_images")
    assert_includes bible.dig("entities", 0, "reference_images"), reference_url
    refute AssetProfiler.technical_reference_prompt?(assets.dig("characters", 0, "visual_prompt"))
    assert AssetProfiler.technical_reference_prompt?(assets.dig("characters", 0, "scale_calibration_prompt"))
  end

  def test_recovers_portrait_misclassified_by_legacy_miniature_pattern
    calibration_url = "https://example.test/calibration.png"
    recovered_url = "https://example.test/regenerated-portrait.png"
    assets = {
      "characters" => [{
        "id" => "char_1", "name" => "Veteran", "entity_type" => "toy_or_figurine",
        "physical_description" => "A scratched red plastic foosball figurine fixed to a steel rod.",
        "visual_prompt" => "CANONICAL NARRATIVE CHARACTER REFERENCE — GENERATION SAFE. MINIATURE CLASS LOCK: same physical height as peer figurines. no ruler, no grid.",
        "image_url" => nil, "reference_images" => [],
        "scale_calibration_image_url" => calibration_url,
        "qa_reference_images" => [calibration_url, recovered_url]
      }],
      "props" => [], "locations" => []
    }

    ScaleContractResolver.apply!(assets, source_prompt: "A miniature foosball player comes alive.")

    assert_equal recovered_url, assets.dig("characters", 0, "image_url")
    assert_equal [recovered_url], assets.dig("characters", 0, "reference_images")
    assert_equal [calibration_url], assets.dig("characters", 0, "qa_reference_images")
  end

  def test_legacy_calibration_sheet_is_migrated_to_qa_only_reference_role
    technical_url = "https://example.test/calibration-sheet.png"
    assets = {
      "characters" => [{
        "id" => "char_1", "name" => "Player", "entity_type" => "toy_or_figurine",
        "physical_description" => "alive red foosball figurine attached to a rod",
        "visual_prompt" => "ABSOLUTE MINIATURE SCALE CALIBRATION SHEET — FIRST PRIORITY. include a visible ruler or measurement grid. SOURCE IDENTITY: alive red foosball figurine",
        "image_url" => technical_url, "reference_images" => [technical_url]
      }],
      "props" => [], "locations" => []
    }

    ScaleContractResolver.apply!(assets, source_prompt: "The foosball hero comes alive without leaving his rod")
    character = assets.dig("characters", 0)

    assert_nil character["image_url"]
    assert_equal [technical_url], character["qa_reference_images"]
    assert_empty character["reference_images"]
    assert character["visual_prompt"].start_with?("CANONICAL NARRATIVE CHARACTER REFERENCE")
    assert_equal "fantastical_agency", character["agency_mode"]
  end

  def test_production_bible_never_exposes_qa_reference_as_narrative_input
    assets = Marshal.load(Marshal.dump(@assets))
    assets["characters"][0]["reference_images"] = ["https://example.test/mara-clean.png", "https://example.test/mara-grid.png"]
    assets["characters"][0]["qa_reference_images"] = ["https://example.test/mara-grid.png"]
    bible = ProductionBible.compile(screenplay: @screenplay, assets: assets)
    character = bible["entities"].first

    assert_equal ["https://example.test/mara-clean.png"], ProductionBible.narrative_reference_images(character)
    assert_equal ["https://example.test/mara-grid.png"], character["qa_reference_images"]
  end

  def test_visual_evaluator_accepts_a_top_level_array_from_vision_model
    selected = [{ "id" => "1.1" }]
    parsed = [{
      "shot_id" => "1.1", "overall_score" => 95, "pass" => true, "issues" => [],
      "identity_score" => 95, "prop_score" => 95, "scale_score" => 95,
      "physics_plausibility_score" => 95
    }]
    result = OpenStruct.new(raw: { "model" => "vision-test" })

    report = VisualConsistencyEvaluator.send(:normalize, parsed, result, selected)

    assert_equal "measured", report["status"]
    assert_equal [], report["failed_shot_ids"]
    assert_equal 95.0, report["average_score"]
  end

  def test_visual_evaluator_accepts_nested_result_payload
    payload = { "result" => { "shots" => [{ "shot_id" => "1.1", "overall_score" => 70, "pass" => true }] } }
    result = OpenStruct.new(raw: { "model" => "vision-test" })

    report = VisualConsistencyEvaluator.send(:normalize, payload, result, [{ "id" => "1.1" }])

    assert_equal "measured", report["status"]
    assert_equal ["1.1"], report["failed_shot_ids"]
  end

  def test_visual_evaluator_hard_fails_scale_even_when_overall_and_model_pass
    parsed = [{
      "shot_id" => "1.1", "overall_score" => 92, "pass" => true,
      "identity_score" => 95, "prop_score" => 94, "scale_score" => 80,
      "physics_plausibility_score" => 92,
      "issues" => ["Character is significantly larger than same-depth peer figures"]
    }]
    result = OpenStruct.new(raw: { "model" => "vision-test" })

    report = VisualConsistencyEvaluator.send(:normalize, parsed, result, [{ "id" => "1.1" }])

    assert_equal ["1.1"], report["failed_shot_ids"]
    assert_includes report.dig("shots", 0, "hard_failures"), "scale_score=80 below 90"
    assert_includes report.dig("shots", 0, "hard_failures"), "critical visible inconsistency"
  end

  def test_visual_evaluator_hard_fails_unrequested_technical_text
    parsed = [{
      "shot_id" => "1.1", "overall_score" => 94, "pass" => true,
      "identity_score" => 95, "prop_score" => 95, "scale_score" => 95,
      "physics_plausibility_score" => 95,
      "issues" => ["Unrequested visible text and a calibration grid were copied into the frame"]
    }]
    result = OpenStruct.new(raw: { "model" => "vision-test" })

    report = VisualConsistencyEvaluator.send(:normalize, parsed, result, [{ "id" => "1.1" }])

    assert_equal ["1.1"], report["failed_shot_ids"]
    assert_includes report.dig("shots", 0, "hard_failures"), "critical visible inconsistency"
  end

  def test_full_control_requires_explicit_creative_and_audio_choices
    result = ProductionModePolicy.resolve(
      input: { "pipeline_mode" => "control", "genre" => "sci_fi" },
      prompt: "A science-fiction mystery"
    )

    refute_empty result["errors"]
    assert result["errors"].any? { |message| message.include?("Sound direction") }
    assert_nil result.dig("direction", "music_style")
  end

  def test_automatic_mode_resolves_sound_and_visual_defaults
    result = ProductionModePolicy.resolve(input: { "pipeline_mode" => "agentic" }, prompt: "A mystery in deep space")

    assert_empty result["errors"]
    assert_equal "sci_fi", result.dig("direction", "genre")
    assert_equal "cyberpunk_synths", result.dig("direction", "music_style")
    assert_equal "none", result.dig("direction", "voice_style")
  end

  def test_visual_evaluator_marks_omitted_rows_incomplete_instead_of_regeneration_candidates
    result = OpenStruct.new(raw: { "model" => "vision-test" })
    report = VisualConsistencyEvaluator.send(
      :normalize,
      { "shots" => [{
        "shot_id" => "1.1", "overall_score" => 95, "pass" => true,
        "identity_score" => 95, "prop_score" => 95, "scale_score" => 95,
        "physics_plausibility_score" => 95
      }] },
      result,
      [{ "id" => "1.1" }, { "id" => "1.2" }]
    )

    assert_equal "incomplete", report["status"]
    assert_includes report["reason"], "1.2"
  end

  def test_script_consistency_reconciles_attached_locomotion_to_camera_motion
    screenplay = Marshal.load(Marshal.dump(@screenplay))
    screenplay["scenes"][0]["shots"][0]["visual_prompt"] = "The mounted player walks towards the camera"
    screenplay["scenes"][0]["shots"][0]["story_event"] = "The mounted player walks towards the camera"
    assets = Marshal.load(Marshal.dump(@assets))
    assets["characters"][0]["entity_type"] = "toy_or_figurine"
    assets["characters"][0]["physical_description"] = "small rigid plastic table player"
    assets["characters"][0]["physical_constraints"] = ["remains fixed and mounted to its metal rod"]
    assets["characters"][0]["scale_reference"] = "8 cm, equal to same-class peer figures"
    bible = ProductionBible.compile(screenplay: screenplay, assets: assets)
    screenplay = ScreenplayPlanner.upgrade!(screenplay, target_duration: 6)
    screenplay = StoryboardPromptCompiler.compile!(screenplay)
    screenplay = ContinuityPlanner.plan!(screenplay, bible)

    ConsistencyEnforcer.apply!(screenplay, OpenStruct.new(domain: :table), assets, production_bible: bible)
    shot = screenplay.dig("scenes", 0, "shots", 0)

    assert screenplay.dig("script_consistency_report", "ready")
    assert_equal 1, screenplay.dig("script_consistency_report", "resolved_count")
    assert_includes shot["visual_prompt"], "remains mechanically attached"
    assert_includes shot["visual_prompt"], "Preserve clear character agency"
    refute_includes shot["visual_prompt"], "walks towards the camera"
    assert_includes shot["visual_prompt"], "HARD CONSISTENCY"
    assert_includes shot["visual_prompt"], "CINEMATIC FREEDOM"
  end

  def test_script_consistency_blocks_undeclared_physical_scale_transformation
    screenplay = Marshal.load(Marshal.dump(@screenplay))
    screenplay["scenes"][0]["shots"][0]["visual_prompt"] = "She grows and becomes giant beside the workbench"
    screenplay["scenes"][0]["shots"][0]["story_event"] = "She grows and becomes giant beside the workbench"
    bible = ProductionBible.compile(screenplay: screenplay, assets: @assets)
    screenplay = ScreenplayPlanner.upgrade!(screenplay, target_duration: 6)
    screenplay = StoryboardPromptCompiler.compile!(screenplay)
    screenplay = ContinuityPlanner.plan!(screenplay, bible)

    ConsistencyEnforcer.apply!(screenplay, OpenStruct.new(domain: :workshop), @assets, production_bible: bible)
    report = ConsistencyEvaluator.evaluate(screenplay: screenplay, production_bible: bible, assets: @assets)

    refute screenplay.dig("script_consistency_report", "ready")
    assert_includes report["issues"].map { |item| item["code"] }, "undeclared_scale_transformation"
    refute report["ready_for_render"]
  end

  def test_production_bible_separates_hard_locks_from_cinematic_freedom
    bible = ProductionBible.compile(screenplay: @screenplay, assets: @assets)

    assert_includes bible.dig("consistency_policy", "hard_locks"), "relative physical scale between every recurring entity"
    assert bible.dig("consistency_policy", "creative_freedoms").any? { |rule| rule.include?("lens") }
    assert_includes bible.dig("consistency_policy", "variant_rule"), "canonical variant"
  end

  def test_complex_scene_gets_one_shared_continuity_plate_as_first_reference
    screenplay = Marshal.load(Marshal.dump(@screenplay))
    bible = ProductionBible.compile(screenplay: screenplay, assets: @assets)
    ContinuityPlanner.plan!(screenplay, bible)
    client = FakeImageClient.new
    ledger = { video_credits_used: 0 }

    result = ContinuityPlatePlanner.generate!(
      screenplay: screenplay,
      production_bible: bible,
      client: client,
      ledger: ledger
    )

    assert_empty result["errors"]
    assert_equal 1, client.calls.size
    assert_equal 1, ledger[:video_credits_used]
    assert_includes client.calls.first[:prompt], "CANONICAL SCENE MASTER"
    assert_includes client.calls.first[:prompt], "No forced perspective"
    assert_includes client.calls.first[:prompt], "no title, text"
    screenplay["scenes"][0]["shots"].each do |shot|
      assert_equal "https://example.test/continuity-1.png", shot.dig("continuity", "reference_image_urls", 0)
    end
  end

  def test_attached_subject_locomotion_is_overridden_before_generation
    override = ConsistencyEnforcer.attachment_override_for(
      "The figure walks toward the camera",
      "The figure remains mounted and fixed to the metal rod"
    )

    assert_includes override, "remains mechanically mounted"
    assert_includes override, "source-defined agency"
    assert_nil ConsistencyEnforcer.attachment_override_for(
      "The owner removes the figure from the rod",
      "The figure remains mounted and fixed to the metal rod"
    )
  end

  def test_storyboard_regeneration_repairs_source_contract_and_returns_fresh_state
    prompt = <<~TEXT
      CHARACTER: ## Visual Description
      Mara is a 32-year-old human mechanic with a black bob haircut, brown eyes, oval face and navy coveralls with a silver patch. Her body proportions and clothing never change.

      ## Scene 1
      A low camera makes her appear larger and more imposing.
    TEXT
    project = RegenerationProject.new(
      prompt: prompt, duration: 6, resolution: "720P", token_budget: 10_000,
      seed: 9, dry_run: true, tokens_used: 0, tokens_remaining: 10_000,
      video_credits_used: 0, direction: { "adaptation_mode" => "faithful" }
    )
    manifest = { "screenplay" => Marshal.load(Marshal.dump(@screenplay)), "assets" => Marshal.load(Marshal.dump(@assets)) }

    result = StoryboardRegenerator.regenerate!(
      project: project, manifest: manifest, shot_ids: ["1.1"], evaluator: PassingVisualEvaluator
    )

    refute_includes result.dig("manifest", "assets", "characters", 0, "physical_description"), "low camera"
    assert_equal "/placeholders/shot_1_1.png", result.dig("images", 0, "image_url")
    assert result.dig("consistency_report", "ready_for_render")
    assert result["generated_at"].positive?
  end

  def test_online_regeneration_refuses_to_spend_image_credits_without_visual_qa_budget
    project = RegenerationProject.new(
      prompt: "Mara in a workshop", duration: 6, resolution: "720P", token_budget: 10_000,
      seed: 9, dry_run: false, tokens_used: 9_900, tokens_remaining: 100,
      video_credits_used: 7, direction: {}
    )

    error = assert_raises(QwenRouter::BudgetExceeded) do
      StoryboardRegenerator.regenerate!(
        project: project,
        manifest: { "screenplay" => @screenplay, "assets" => @assets },
        shot_ids: ["1.1"]
      )
    end

    assert_includes error.message, "No image credits were spent"
  end

  def test_explicit_overrun_authorization_bypasses_regeneration_preflight
    project = RegenerationProject.new(token_budget: 10_000, tokens_used: 10_000, tokens_remaining: 0)

    assert_nil StoryboardRegenerator.ensure_project_visual_budget!(
      project: project, shot_count: 6, allow_token_overrun: true
    )
  end

  def test_visual_qa_override_is_bound_to_exact_storyboard_images
    screenplay = { "scenes" => [{ "shots" => [{ "id" => "1.1", "image_url" => "https://example.test/a.png" }] }] }
    report = {
      "ready_for_render" => false,
      "issues" => [{ "severity" => "critical", "code" => "visual_audit_unavailable" }]
    }
    manifest = {}

    assert ConsistencyOverridePolicy.overrideable?(report)
    ConsistencyOverridePolicy.authorize!(manifest: manifest, screenplay: screenplay)
    assert ConsistencyOverridePolicy.valid?(manifest: manifest, screenplay: screenplay)
    assert ConsistencyOverridePolicy.apply!(report: report, manifest: manifest, screenplay: screenplay)
    assert report["ready_for_render"]

    screenplay["scenes"][0]["shots"][0]["image_url"] = "https://example.test/b.png"
    refute ConsistencyOverridePolicy.valid?(manifest: manifest, screenplay: screenplay)
  end

  def test_visual_override_never_bypasses_script_or_asset_failure
    report = {
      "ready_for_render" => false,
      "issues" => [
        { "severity" => "critical", "code" => "visual_audit_unavailable" },
        { "severity" => "critical", "code" => "undeclared_identity_transformation" }
      ]
    }

    refute ConsistencyOverridePolicy.overrideable?(report)
  end

  def test_paid_preproduction_services_honor_project_cancellation_before_provider_calls
    cancellation = -> { raise ActiveRecord::RecordNotFound, "project deleted" }
    project = RegenerationProject.new(
      prompt: "A canonical human in a workshop", duration: 6, resolution: "720P",
      token_budget: 10_000, seed: 1, dry_run: false, direction: {}
    )
    bible = ProductionBible.compile(screenplay: @screenplay, assets: @assets)

    assert_raises(ActiveRecord::RecordNotFound) do
      AssetProfiler.profile!(
        @screenplay.deep_dup, project, force_mock: true,
        cancellation_check: cancellation
      )
    end
    assert_raises(ActiveRecord::RecordNotFound) do
      VisualConsistencyEvaluator.evaluate(
        screenplay: @screenplay.deep_dup,
        production_bible: bible,
        cancellation_check: cancellation
      )
    end
    assert_raises(ActiveRecord::RecordNotFound) do
      ContinuityPlatePlanner.generate!(
        screenplay: @screenplay.deep_dup,
        production_bible: bible,
        client: Object.new,
        ledger: {},
        cancellation_check: cancellation
      )
    end
  end

  def test_recoverable_video_digest_changes_with_prompts_and_canonical_assets
    manifest = { "screenplay" => @screenplay.deep_dup, "assets" => @assets.deep_dup }
    original = ConsistencyOverridePolicy.render_contract_digest(manifest)

    reordered = manifest.deep_dup
    reordered["screenplay"] = reordered["screenplay"].to_a.reverse.to_h
    reordered.dig("assets", "characters", 0).replace(
      reordered.dig("assets", "characters", 0).to_a.reverse.to_h
    )
    assert_equal original, ConsistencyOverridePolicy.render_contract_digest(reordered)

    changed_prompt = manifest.deep_dup
    changed_prompt.dig("screenplay", "scenes", 0, "shots", 0)["visual_prompt"] = "A different action"
    refute_equal original, ConsistencyOverridePolicy.render_contract_digest(changed_prompt)

    changed_asset = manifest.deep_dup
    changed_asset.dig("assets", "characters", 0)["wardrobe"] = "a different uniform"
    refute_equal original, ConsistencyOverridePolicy.render_contract_digest(changed_asset)
  end

  def test_legacy_video_checkpoint_can_issue_one_shot_clip_recovery_authorization
    created_at = Time.current.change(usec: 0)
    manifest = {
      "screenplay" => @screenplay.deep_dup,
      "assets" => @assets.deep_dup,
      "video_jobs" => [{ "shot_id" => "1.1", "task_id" => "legacy-task-1" }],
      "pending_video_review" => {
        "available" => true,
        "video_sha256" => "legacy-video-sha",
        "render_contract_digest" => "legacy-noncanonical-digest",
        "created_at" => created_at.iso8601
      }
    }

    assert ConsistencyOverridePolicy.legacy_checkpoint_unchanged?(
      manifest: manifest, project_updated_at: created_at + 1.second
    )
    refute ConsistencyOverridePolicy.legacy_checkpoint_unchanged?(
      manifest: manifest, project_updated_at: created_at + 3.seconds
    )

    ConsistencyOverridePolicy.authorize_legacy_clip_recovery!(manifest: manifest)
    assert ConsistencyOverridePolicy.legacy_clip_recovery_valid?(manifest: manifest)

    manifest.dig("screenplay", "scenes", 0, "shots", 0)["visual_prompt"] = "Changed after authorization"
    refute ConsistencyOverridePolicy.legacy_clip_recovery_valid?(manifest: manifest)
  end

  def test_token_predictor_reserves_visual_repairs_and_video_qa
    forecast = ProductionTokenPredictor.estimate(
      input: {
        prompt: "A miniature foosball player kicks a ball, is replaced, restored, and returns in a flashback.",
        duration: 55,
        resolution: "720P",
        token_budget: 18_000,
        pipeline_mode: "agentic",
        adaptation_mode: "faithful"
      },
      history_scope: []
    )

    assert_operator forecast["expected_tokens"], :>, 18_000
    assert_operator forecast.dig("breakdown", "storyboard_visual_qa"), :>, 0
    assert_operator forecast.dig("breakdown", "repair_and_recheck_reserve"), :>, 0
    assert_operator forecast.dig("breakdown", "final_video_qa"), :>, 0
    assert forecast["overrun_required"]
    assert_includes forecast["risk_factors"], "Miniature or scale"
  end

  def test_token_forecast_approval_digest_changes_with_cinematic_configuration
    base = {
      prompt: "A human explorer crosses a silent observatory.",
      duration: 45,
      resolution: "720P",
      token_budget: 40_000,
      pipeline_mode: "control"
    }
    original = ProductionTokenPredictor.approval_digest(base)

    refute_equal original, ProductionTokenPredictor.approval_digest(base.merge(duration: 90))
    refute_equal original, ProductionTokenPredictor.approval_digest(base.merge(resolution: "1080P"))
    refute_equal original, ProductionTokenPredictor.approval_digest(base.merge(prompt: "A different film"))
  end

  def test_token_forecast_digest_treats_html_and_json_newlines_as_the_same_script
    json_input = {
      prompt: "SCENE 1\nA miniature player strikes the ball.\nSCENE 2\nThe ball reaches the goal.",
      brain_dump: "Keep the scale fixed.\nPreserve the same uniform.",
      duration: 45,
      resolution: "720P",
      token_budget: 18_000
    }
    html_input = json_input.merge(
      prompt: json_input[:prompt].gsub("\n", "\r\n"),
      brain_dump: json_input[:brain_dump].gsub("\n", "\r\n")
    )

    assert_equal ProductionTokenPredictor.approval_digest(json_input),
      ProductionTokenPredictor.approval_digest(html_input)
  end

  def test_token_forecast_requires_an_exact_explicit_approval
    forecast = ProductionTokenPredictor.estimate(
      input: {
        prompt: "A miniature player strikes a ball in slow motion.",
        duration: 60,
        resolution: "1080P",
        token_budget: 5_000
      },
      history_scope: []
    )

    assert forecast["overrun_required"]
    refute ProductionTokenPredictor.approval_valid?(forecast: forecast, supplied_digest: forecast["approval_digest"], approved: false)
    refute ProductionTokenPredictor.approval_valid?(forecast: forecast, supplied_digest: "stale-digest", approved: true)
    assert ProductionTokenPredictor.approval_valid?(forecast: forecast, supplied_digest: forecast["approval_digest"], approved: true)
  end

  def test_token_predictor_projects_unfinished_visual_qa_from_current_history
    shots = 12.times.map { |index| { "id" => "1.#{index + 1}" } }
    current_manifest = {
      "production_bible" => { "entities" => ["CHARACTER_1"] },
      "screenplay" => { "scenes" => [{ "shots" => shots }] },
      "consistency_report" => {
        "visual_metrics" => { "status" => "blocked", "partial_shots" => shots.first(3) }
      },
      "budget_ledger" => {
        "calls" => [{ "stage" => "visual_consistency", "tokens" => 6_000 }]
      }
    }
    legacy_manifest = { "screenplay" => { "scenes" => [{ "shots" => shots }] } }
    attributes = {
      tokens_used: 18_000,
      duration: 55,
      prompt: "A miniature player and ball remain consistent across every shot.",
      resolution: "720P"
    }
    current_project = OpenStruct.new(**attributes, manifest: current_manifest)
    legacy_project = OpenStruct.new(**attributes, manifest: legacy_manifest)
    input = attributes.slice(:prompt, :duration, :resolution).merge(token_budget: 18_000)

    current_forecast = ProductionTokenPredictor.estimate(input: input, history_scope: [current_project])
    legacy_forecast = ProductionTokenPredictor.estimate(input: input, history_scope: [legacy_project])

    assert_equal 1, current_forecast["historical_samples"]
    assert_equal 1, current_forecast["current_pipeline_samples"]
    assert_operator current_forecast["expected_tokens"], :>, legacy_forecast["expected_tokens"]
  end

  def test_qwen_ledger_records_authorized_tokens_beyond_budget
    ledger = {
      tokens_used: 100,
      tokens_remaining: 0,
      token_budget: 100,
      allow_token_overrun: true,
      calls: []
    }
    assert QwenRouter.overrun_authorized?(ledger)
    QwenRouter.record_usage!(ledger, stage: :visual_consistency, model: "qwen-test", tokens_used: 50)

    assert_equal 150, ledger[:tokens_used]
    assert_equal 0, ledger[:tokens_remaining]
    assert_equal 50, ledger[:tokens_over_budget]
  end

  def test_video_evaluator_samples_real_clip_frames_for_temporal_review
    Dir.mktmpdir("consistency_test_") do |dir|
      clip = File.join(dir, "clip.mp4")
      system(
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-f", "lavfi", "-i", "color=c=blue:s=320x180:d=3",
        "-c:v", "libx264", "-pix_fmt", "yuv420p", clip
      )
      frames = VideoConsistencyEvaluator.send(:extract_frames, clip, dir, "1.1")

      assert_operator frames.size, :>=, VideoConsistencyEvaluator::MIN_FRAMES_PER_SHOT
      assert frames.all? { |path| File.file?(path) && File.size(path).positive? }
    end
  end

  def test_video_evaluator_treats_qualified_minor_morphing_as_a_warning
    parsed = {
      "shots" => [{
        "shot_id" => "1.1", "overall_score" => 86, "pass" => false,
        "identity_score" => 86, "prop_score" => 86, "scale_score" => 92,
        "temporal_stability_score" => 86, "physics_score" => 86,
        "issues" => ["Minor morphing in one hand; slight texture jitter on the face."]
      }]
    }

    report = VideoConsistencyEvaluator.send(:normalize, parsed, ["1.1"])
    row = report["shots"].first

    assert row["pass"]
    refute row["model_pass"]
    assert_empty row["hard_failures"]
  end

  def test_video_evaluator_still_hard_fails_unqualified_morphing
    parsed = {
      "shots" => [{
        "shot_id" => "1.1", "overall_score" => 90, "pass" => true,
        "identity_score" => 90, "prop_score" => 90, "scale_score" => 92,
        "temporal_stability_score" => 90, "physics_score" => 90,
        "issues" => ["The protagonist morphs into a different body between frames."]
      }]
    }

    row = VideoConsistencyEvaluator.send(:normalize, parsed, ["1.1"])["shots"].first

    refute row["pass"]
    assert_includes row["hard_failures"], "critical visible inconsistency"
  end

  def test_video_evaluator_marks_an_omitted_audit_as_unavailable_not_visual_failure
    row = VideoConsistencyEvaluator.send(:normalize, { "shots" => [] }, ["1.1"])["shots"].first

    assert_equal "unavailable", row["audit_status"]
    assert_nil row["pass"]
    assert_nil row["overall_score"]
  end

  def test_video_synth_uses_the_correct_character_and_multi_entity_keyframe
    assets = Marshal.load(Marshal.dump(@assets))
    assets["characters"] << {
      "id" => "char_2",
      "name" => "Ivo",
      "entity_type" => "human",
      "physical_description" => "older man with gray beard",
      "image_url" => "https://example.test/ivo.png",
      "reference_images" => ["https://example.test/ivo.png"]
    }
    bible = ProductionBible.compile(screenplay: @screenplay, assets: assets)
    shots = @screenplay["scenes"].first["shots"]
    shots[0]["continuity"] = {
      "required_entity_ids" => ["CHARACTER_2", "LOCATION_1"],
      "render_strategy" => "character_r2v"
    }
    shots[1]["continuity"] = {
      "required_entity_ids" => ["CHARACTER_1", "PROP_1", "LOCATION_1"],
      "render_strategy" => "keyframe_i2v"
    }
    shots[1]["image_url"] = "https://example.test/keyframe.png"
    shots[0]["duration"] = 7
    shots[1]["duration"] = 6

    Dir.mktmpdir("video_synth_test_") do |dir|
      clip = File.join(dir, "source.mp4")
      system("ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "color=c=black:s=320x180:d=1", "-c:v", "libx264", "-pix_fmt", "yuv420p", clip)
      client = FakeVideoClient.new(clip)

      VideoSynth.run!(
        @screenplay,
        client: client,
        workdir: dir,
        resolution: "720P",
        assets: assets,
        production_bible: bible
      )

      assert_equal :r2v, client.inputs[0][:mode]
      assert_equal "https://example.test/ivo.png", client.inputs[0][:ref_image_url]
      assert_equal :i2v, client.inputs[1][:mode]
      assert_equal "https://example.test/keyframe.png", client.inputs[1][:first_frame_url]
      assert_equal [5, 5], client.inputs.map { |input| input[:provider_duration] }
      assert_equal [7, 6], client.inputs.map { |input| input[:editorial_duration] }
    end
  end

  def test_full_control_video_synth_does_not_spend_hidden_repair_credits
    screenplay = Marshal.load(Marshal.dump(@screenplay))
    bible = ProductionBible.compile(screenplay: screenplay, assets: @assets)
    shot = screenplay.dig("scenes", 0, "shots", 0)
    shot["continuity"] = {
      "required_entity_ids" => ["CHARACTER_1"],
      "render_strategy" => "character_r2v"
    }
    evaluator = lambda do |**|
      {
        "status" => "measured", "average_score" => 75,
        "failed_shot_ids" => ["1.1"],
        "shots" => [{ "shot_id" => "1.1", "pass" => false, "issues" => ["identity drift"] }]
      }
    end

    Dir.mktmpdir("video_synth_control_test_") do |dir|
      clip = File.join(dir, "source.mp4")
      system("ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "color=c=black:s=320x180:d=1", "-c:v", "libx264", "-pix_fmt", "yuv420p", clip)
      client = FakeVideoClient.new(clip)

      _jobs, _paths, report = VideoSynth.run!(
        screenplay, client: client, workdir: dir, resolution: "720P",
        assets: @assets, production_bible: bible,
        quality_evaluator: evaluator, auto_repair: false
      )

      assert_equal [], report["automatic_repairs_attempted"]
      assert_equal "disabled_by_full_control", report["repair_policy"]
    end
  end

  def test_video_synth_reuses_approved_cached_clips_without_new_video_credits
    screenplay = Marshal.load(Marshal.dump(@screenplay))
    bible = ProductionBible.compile(screenplay: screenplay, assets: @assets)

    Dir.mktmpdir("video_synth_cache_test_") do |dir|
      source = File.join(dir, "source.mp4")
      system("ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "color=c=black:s=320x180:d=1", "-c:v", "libx264", "-pix_fmt", "yuv420p", source)
      first_client = FakeVideoClient.new(source)
      _jobs, _paths, first_report = VideoSynth.run!(
        screenplay, client: first_client, workdir: dir, resolution: "720P",
        assets: @assets, production_bible: bible,
        quality_evaluator: PassingVisualEvaluator.method(:evaluate), auto_repair: false
      )
      assert_equal 2, first_client.inputs.size

      second_client = FakeVideoClient.new(source)
      jobs, _paths, second_report = VideoSynth.run!(
        screenplay, client: second_client, workdir: dir, resolution: "720P",
        assets: @assets, production_bible: bible,
        quality_evaluator: PassingVisualEvaluator.method(:evaluate),
        prior_quality_report: first_report, auto_repair: false
      )

      assert_empty second_client.inputs
      assert_equal ["1.1", "1.2"], second_report["reused_approved_shot_ids"]
      assert jobs.all? { |job| job[:status] == "REUSED_APPROVED_CLIP" && job[:task_id].nil? }
    end
  end

  def test_video_synth_invalidates_only_the_cached_clip_whose_contract_changed
    screenplay = Marshal.load(Marshal.dump(@screenplay))
    bible = ProductionBible.compile(screenplay: screenplay, assets: @assets)

    Dir.mktmpdir("video_synth_contract_test_") do |dir|
      source = File.join(dir, "source.mp4")
      system("ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "color=c=black:s=320x180:d=1", "-c:v", "libx264", "-pix_fmt", "yuv420p", source)
      first_client = FakeVideoClient.new(source)
      _jobs, _paths, first_report = VideoSynth.run!(
        screenplay, client: first_client, workdir: dir, resolution: "720P",
        assets: @assets, production_bible: bible,
        quality_evaluator: PassingVisualEvaluator.method(:evaluate), auto_repair: false
      )

      screenplay.dig("scenes", 0, "shots", 0)["visual_prompt"] = "A deliberately changed shot contract"
      second_client = FakeVideoClient.new(source)
      _jobs, _paths, second_report = VideoSynth.run!(
        screenplay, client: second_client, workdir: dir, resolution: "720P",
        assets: @assets, production_bible: bible,
        quality_evaluator: PassingVisualEvaluator.method(:evaluate),
        prior_quality_report: first_report, auto_repair: false
      )

      assert_equal ["1.1"], second_client.inputs.map { |input| input[:id] }
      assert_equal ["1.2"], second_report["reused_approved_shot_ids"]
    end
  end

  def test_video_synth_reaudits_an_unavailable_cached_clip_without_regenerating_it
    screenplay = Marshal.load(Marshal.dump(@screenplay))
    bible = ProductionBible.compile(screenplay: screenplay, assets: @assets)

    Dir.mktmpdir("video_synth_reaudit_test_") do |dir|
      source = File.join(dir, "source.mp4")
      system("ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "color=c=black:s=320x180:d=1", "-c:v", "libx264", "-pix_fmt", "yuv420p", source)
      first_client = FakeVideoClient.new(source)
      _jobs, _paths, first_report = VideoSynth.run!(
        screenplay, client: first_client, workdir: dir, resolution: "720P",
        assets: @assets, production_bible: bible,
        quality_evaluator: PassingVisualEvaluator.method(:evaluate), auto_repair: false
      )
      first_report["shots"].each do |row|
        row["pass"] = nil
        row["audit_status"] = "unavailable"
        row["issues"] = ["video vision audit unavailable: temporary provider error"]
      end

      second_client = FakeVideoClient.new(source)
      VideoSynth.run!(
        screenplay, client: second_client, workdir: dir, resolution: "720P",
        assets: @assets, production_bible: bible,
        quality_evaluator: PassingVisualEvaluator.method(:evaluate),
        prior_quality_report: first_report, auto_repair: false
      )

      assert_empty second_client.inputs
    end
  end

  def test_video_synth_restores_legacy_provider_tasks_and_reaudits_before_regeneration
    screenplay = Marshal.load(Marshal.dump(@screenplay))
    bible = ProductionBible.compile(screenplay: screenplay, assets: @assets)

    Dir.mktmpdir("video_synth_legacy_restore_test_") do |dir|
      source = File.join(dir, "source.mp4")
      system("ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "color=c=black:s=320x180:d=1", "-c:v", "libx264", "-pix_fmt", "yuv420p", source)
      first_client = FakeVideoClient.new(source)
      jobs, _paths, first_report = VideoSynth.run!(
        screenplay, client: first_client, workdir: dir, resolution: "720P",
        assets: @assets, production_bible: bible,
        quality_evaluator: PassingVisualEvaluator.method(:evaluate), auto_repair: false
      )
      first_report.delete("evaluator_version")
      jobs.each { |job| job.delete(:clip_contract_digest) }
      screenplay.dig("scenes", 0, "shots").each do |shot|
        FileUtils.rm_f(VideoSynth.cached_clip_path(dir, shot["id"]))
        FileUtils.rm_f(VideoSynth.clip_contract_path(dir, shot["id"]))
      end

      second_client = FakeVideoClient.new(source)
      _jobs, _paths, report = VideoSynth.run!(
        screenplay, client: second_client, workdir: dir, resolution: "720P",
        assets: @assets, production_bible: bible,
        quality_evaluator: PassingVisualEvaluator.method(:evaluate),
        prior_quality_report: first_report, prior_video_jobs: jobs,
        allow_legacy_task_recovery: true, auto_repair: false
      )

      assert_empty second_client.inputs
      assert_equal 2, second_client.poll_calls.size
      assert report["legacy_clip_reaudit_performed"]
      assert_equal ["1.1", "1.2"], report["restored_provider_task_shot_ids"]
    end
  end

  def test_video_synth_reaudits_each_recovered_legacy_clip_when_another_task_expired
    screenplay = Marshal.load(Marshal.dump(@screenplay))
    bible = ProductionBible.compile(screenplay: screenplay, assets: @assets)
    evaluator = lambda do |shot_paths:, **|
      rows = shot_paths.keys.map do |shot_id|
        { "shot_id" => shot_id, "pass" => true, "overall_score" => 100 }
      end
      {
        "evaluator_version" => VideoConsistencyEvaluator::VERSION,
        "status" => "measured", "average_score" => 100,
        "failed_shot_ids" => [], "shots" => rows
      }
    end

    Dir.mktmpdir("video_synth_partial_legacy_restore_test_") do |dir|
      source = File.join(dir, "source.mp4")
      system("ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "color=c=black:s=320x180:d=1", "-c:v", "libx264", "-pix_fmt", "yuv420p", source)
      first_client = FakeVideoClient.new(source)
      jobs, = VideoSynth.run!(
        screenplay, client: first_client, workdir: dir, resolution: "720P",
        assets: @assets, production_bible: bible,
        quality_evaluator: evaluator, auto_repair: false
      )
      jobs.each { |job| job.delete(:clip_contract_digest) }
      screenplay.dig("scenes", 0, "shots").each do |shot|
        FileUtils.rm_f(VideoSynth.cached_clip_path(dir, shot["id"]))
        FileUtils.rm_f(VideoSynth.clip_contract_path(dir, shot["id"]))
      end

      second_client = FakeVideoClient.new(source, failed_poll_task_ids: ["task-1.2"])
      _new_jobs, _paths, report = VideoSynth.run!(
        screenplay, client: second_client, workdir: dir, resolution: "720P",
        assets: @assets, production_bible: bible,
        quality_evaluator: evaluator,
        prior_quality_report: { "status" => "measured", "shots" => [] },
        prior_video_jobs: jobs, allow_legacy_task_recovery: true, auto_repair: false
      )

      assert_equal ["1.1"], report["restored_provider_task_shot_ids"]
      assert_equal ["1.2"], second_client.inputs.map { |input| input[:id] }
      assert report["legacy_clip_reaudit_performed"]
    end
  end

  def test_video_synth_rejects_a_legacy_calibration_sheet_as_r2v_input
    assets = Marshal.load(Marshal.dump(@assets))
    character = assets["characters"].first
    character["entity_type"] = "toy_or_figurine"
    character["physical_description"] = "foosball figurine"
    character["visual_prompt"] = "ABSOLUTE MINIATURE SCALE CALIBRATION SHEET — FIRST PRIORITY with visible ruler"
    character["image_url"] = "https://example.test/calibration.png"
    character["reference_images"] = [character["image_url"]]
    screenplay = Marshal.load(Marshal.dump(@screenplay))
    bible = ProductionBible.compile(screenplay: screenplay, assets: assets)
    shot = screenplay.dig("scenes", 0, "shots", 0)
    shot["continuity"] = { "required_entity_ids" => ["CHARACTER_1"], "render_strategy" => "character_r2v" }

    Dir.mktmpdir("video_synth_reference_role_test_") do |dir|
      clip = File.join(dir, "source.mp4")
      system("ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "color=c=black:s=320x180:d=1", "-c:v", "libx264", "-pix_fmt", "yuv420p", clip)
      client = FakeVideoClient.new(clip)
      VideoSynth.run!(screenplay, client: client, workdir: dir, resolution: "720P", assets: assets, production_bible: bible)

      assert_equal :t2v, client.inputs.first[:mode]
      assert_nil client.inputs.first[:ref_image_url]
    end
  end

  def test_final_video_gate_honors_an_explicit_one_render_override
    failed_report = {
      "status" => "measured",
      "average_score" => 90.2,
      "failed_shot_ids" => ["1.4", "6.1"]
    }
    engine = ShowrunnerEngine.new(config: {
      prompt: "A canonical miniature", output: "/tmp/not-written.mp4", target_duration: 5,
      resolution: "720P", token_budget: 2_000, dry_run: false, adaptation_mode: "faithful"
    })
    engine.instance_variable_set(:@video_consistency_report, failed_report.deep_dup)

    error = assert_raises(RuntimeError) do
      engine.send(
        :enforce_video_consistency_gate!,
        dry: false, quality_evaluator_present: true, strict_consistency: true,
        allow_visual_qa_override: false
      )
    end
    assert_includes error.message, "1.4, 6.1"

    engine.send(
      :enforce_video_consistency_gate!,
      dry: false, quality_evaluator_present: true, strict_consistency: true,
      allow_visual_qa_override: true
    )
    assert engine.video_consistency_report["override_applied"]
    assert_equal ["1.4", "6.1"], engine.video_consistency_report["failed_shot_ids"]
  end

  def test_final_video_gate_reports_full_control_without_claiming_automatic_repair
    engine = ShowrunnerEngine.new(config: {
      prompt: "A canonical miniature", output: "/tmp/not-written.mp4", target_duration: 5,
      resolution: "720P", token_budget: 2_000, dry_run: false, adaptation_mode: "faithful"
    })
    engine.instance_variable_set(:@video_consistency_report, {
      "status" => "measured", "failed_shot_ids" => ["1.1"],
      "automatic_repairs_attempted" => [], "repair_policy" => "disabled_by_full_control"
    })

    error = assert_raises(RuntimeError) do
      engine.send(
        :enforce_video_consistency_gate!,
        dry: false, quality_evaluator_present: true, strict_consistency: true,
        allow_visual_qa_override: false
      )
    end

    assert_includes error.message, "Full Control"
    refute_includes error.message, "after automatic repair"
  end
end
