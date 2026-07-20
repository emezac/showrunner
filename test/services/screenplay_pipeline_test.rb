# frozen_string_literal: true

require "minitest/autorun"
require "active_support/all"
require "active_record"
require "ostruct"

require_relative "../../lib/showrunner"
require_relative "../../app/services/production_bible"

class ScreenplayPipelineTest < Minitest::Test
  def test_upgrades_legacy_screenplay_and_compiles_exact_edl
    screenplay = {
      "title" => "Human drama",
      "scenes" => [
        {
          "heading" => "INT. KITCHEN - NIGHT",
          "action" => "Ana places the unopened letter between them.",
          "dialogue" => [{ "character" => "ANA", "line" => "I need you to read this." }],
          "shots" => [
            { "id" => "1.1", "camera" => "locked wide", "visual_prompt" => "Ana enters and places the letter" },
            { "id" => "1.2", "camera" => "close-up", "visual_prompt" => "Luis recognizes the handwriting" }
          ]
        },
        {
          "heading" => "EXT. STREET - DAWN",
          "action" => "Luis leaves with the opened letter.",
          "shots" => [
            { "id" => "2.1", "camera" => "tracking left to right", "visual_prompt" => "Luis walks into the empty street" }
          ]
        }
      ]
    }

    result = ScreenplayPlanner.upgrade!(screenplay, target_duration: 20, seed: 7)
    first_scene = result["scenes"].first
    first_shot = first_scene["shots"].first
    boundary_shot = first_scene["shots"].last

    assert_equal "3.0", result["schema_version"]
    assert_equal "locked wide", first_shot["camera"]
    assert first_scene.values_at("objective", "conflict", "turn", "outcome").all?(&:present?)
    assert_equal "establishing", first_shot["editorial_role"]
    assert_equal "fade", boundary_shot.dig("transition_out", "type")
    assert_equal 20.0, result.dig("edit_decision_list", "planned_duration")
    assert_equal %w[1.1 1.2 2.1], result.dig("edit_decision_list", "entries").map { |entry| entry["clip_id"] }

    report = ScreenplayEvaluator.evaluate(result, target_duration: 20)
    assert report["ready_for_storyboard"], report["issues"].inspect
  end

  def test_compiler_preserves_story_event_states_and_camera
    screenplay = ScreenplayPlanner.upgrade!(
      {
        "scenes" => [{
          "heading" => "WORKSHOP",
          "action" => "Mara rolls an amber sphere.",
          "shots" => [{
            "camera" => "macro locked camera",
            "visual_prompt" => "Mara's fingertip pushes the sphere left to right",
            "exit_state" => { "sphere_position" => "beside Mara's right hand" }
          }]
        }]
      },
      target_duration: 8
    )

    StoryboardPromptCompiler.compile!(screenplay)
    shot = screenplay["scenes"].first["shots"].first

    assert_includes shot["visual_prompt"], "SHOT PURPOSE:"
    assert_includes shot["visual_prompt"], "ENTRY STATE:"
    assert_includes shot["visual_prompt"], "sphere_position=beside Mara's right hand"
    assert_includes shot["visual_prompt"], "CAMERA: macro locked camera"
    assert_equal "Mara's fingertip pushes the sphere left to right", shot["source_visual_prompt"]
  end

  def test_long_direction_is_preserved_but_reduced_to_an_atomic_generation_action
    long_direction = ([
      "The player approaches the ball while the camera circles the table and the light changes.",
      "The boot touches the ball, the ball accelerates toward the goal and the player remains on the rod.",
      "The final frame holds the ball beside the goalkeeper."
    ] * 8).join(" ")
    screenplay = ScreenplayPlanner.upgrade!(
      { "scenes" => [{ "action" => long_direction, "shots" => [{ "visual_prompt" => long_direction }] }] },
      target_duration: 8
    )

    StoryboardPromptCompiler.compile!(screenplay)
    shot = screenplay["scenes"].first["shots"].first
    report = ScreenplayEvaluator.evaluate(screenplay, target_duration: 8)

    assert_equal long_direction, shot["source_visual_prompt"]
    assert_operator shot["generation_action"].length, :<=, 600
    assert report["ready_for_storyboard"]
    assert_includes report["issues"].map { |issue| issue["code"] }, "overlong_source_direction"
  end

  def test_replanning_respects_manual_duration_weights_and_repairs_duplicate_ids
    screenplay = ScreenplayPlanner.upgrade!(
      {
        "scenes" => [{
          "shots" => [
            { "id" => "duplicate", "visual_prompt" => "First action" },
            { "id" => "duplicate", "visual_prompt" => "Second action" },
            { "id" => "duplicate", "visual_prompt" => "Third action" }
          ]
        }]
      },
      target_duration: 18
    )
    shots = screenplay["scenes"].first["shots"]
    shots[0]["duration"] = 10
    shots[1]["duration"] = 2
    shots[2]["duration"] = 2

    replanned = ScreenplayPlanner.upgrade!(screenplay, target_duration: 18)
    durations = replanned["scenes"].first["shots"].map { |shot| shot["duration"] }
    ids = replanned["scenes"].first["shots"].map { |shot| shot["id"] }

    assert_operator durations.first, :>, durations[1]
    assert_equal ids.size, ids.uniq.size
    assert_equal 18.0, replanned.dig("edit_decision_list", "planned_duration")
  end

  def test_scene_architecture_is_authoritative_over_shot_generation_call
    parsed = {
      "scenes" => [{
        "id" => "scene_01",
        "objective" => "A contradictory rewritten objective",
        "shots" => [{ "visual_prompt" => "Ana opens the letter" }]
      }]
    }
    architecture = {
      "story_outline" => { "premise" => "Ana must confront a family secret" },
      "scene_cards" => [{
        "id" => "scene_01",
        "objective" => "Ana gets Luis to read the letter",
        "conflict" => "Luis refuses",
        "turn" => "Ana reveals the signature",
        "outcome" => "Luis opens the letter",
        "continuity_in" => { "letter" => "sealed" },
        "continuity_out" => { "letter" => "open" },
        "dialogue" => []
      }]
    }

    Screenwriter.apply_architecture!(parsed, architecture)

    assert_equal "Ana gets Luis to read the letter", parsed.dig("scenes", 0, "objective")
    assert_equal({ "letter" => "open" }, parsed.dig("scenes", 0, "continuity_out"))
    assert_equal "Ana opens the letter", parsed.dig("scenes", 0, "shots", 0, "visual_prompt")
  end

  def test_story_architect_normalizes_nearby_scene_schema_without_an_extra_call
    response = {
      "title" => "The repaired player",
      "outline" => { "premise" => "A discarded toy earns a return to the table" },
      "scenes" => [{
        "sceneId" => "discarded",
        "title" => "THE DUMP",
        "goal" => "The craftsman notices the toy",
        "obstacle" => "The toy is buried in refuse",
        "turning_point" => "Sunlight catches its scratched paint",
        "result" => "The craftsman retrieves it"
      }]
    }

    normalized = StoryArchitect.normalize_response(response)

    assert StoryArchitect.valid?(normalized)
    assert_equal "discarded", normalized.dig("scene_cards", 0, "id")
    assert_equal "The craftsman notices the toy", normalized.dig("scene_cards", 0, "objective")
    assert_equal "Sunlight catches its scratched paint", normalized.dig("scene_cards", 0, "turn")
  end

  def test_story_architect_tolerates_arrays_in_optional_hash_paths
    response = {
      "story" => ["unexpected", "array"],
      "architecture" => [{ "metadata" => true }],
      "story_architecture" => [{
        "scenes" => [{
          "id" => "scene_01",
          "heading" => "FOOSBALL TABLE",
          "objective" => "The player returns to the field"
        }]
      }]
    }

    normalized = StoryArchitect.normalize_response(response)

    assert StoryArchitect.valid?(normalized)
    assert_equal "scene_01", normalized.dig("scene_cards", 0, "id")
    assert_equal "Untitled", normalized["title"]
  end

  def test_story_architect_hash_path_never_indexes_an_array_with_a_string
    response = { "story" => [{ "outline" => { "premise" => "Wrong nesting" } }] }

    assert_nil StoryArchitect.hash_path(response, "story", "outline")
    assert_nil StoryArchitect.hash_path(response, "story", "title")
  end

  def test_story_architect_repairs_valid_json_that_has_no_scene_collection
    calls = []
    responses = [
      [{ "title" => "Incomplete", "premise" => "A toy returns" }, OpenStruct.new],
      [{ "scene_cards" => [{ "id" => "scene_01", "heading" => "THE TABLE", "objective" => "Return" }] }, OpenStruct.new]
    ]
    fake_call = lambda do |**kwargs|
      calls << kwargs
      responses.shift
    end

    original_call = QwenRouter.method(:call_json)
    QwenRouter.define_singleton_method(:call_json, &fake_call)
    begin
      result = StoryArchitect.generate!(
        selection: OpenStruct.new(domain: :foosball, tone: :hopeful, base_story: { genes: [] }),
        prompt: "A discarded foosball player is repaired and returns to the table.",
        shape: { scenes: 7, target_duration: 75 },
        ledger: { tokens_remaining: 85_000 },
        config: OpenStruct.new,
        adaptation_mode: "faithful"
      )
    ensure
      QwenRouter.define_singleton_method(:call_json, original_call)
    end

    assert_equal 2, calls.size
    assert_equal :story_architecture, calls.first[:stage]
    assert_operator calls.first[:max_tokens], :>=, 2_900
    assert_equal :story_architecture_repair, calls.last[:stage]
    assert_equal "scene_01", result.first.dig("scene_cards", 0, "id")
  end

  def test_screenwriter_normalizes_scene_and_shot_hashes_keyed_by_id
    response = {
      "screenplay" => {
        "title" => "Return to the table",
        "scenes" => {
          "opening" => {
            "scene_id" => "opening",
            "title" => "THE WORKSHOP",
            "action" => "The craftsman repairs the worn player.",
            "shots" => {
              "repair" => {
                "shot_id" => "repair",
                "description" => "A fine brush restores the red paint.",
                "framing" => "macro"
              }
            }
          }
        }
      }
    }

    normalized = Screenwriter.normalize_generated_response(response)

    assert_equal "Return to the table", normalized["title"]
    assert_equal "opening", normalized.dig("scenes", 0, "id")
    assert_equal "repair", normalized.dig("scenes", 0, "shots", 0, "id")
    assert_equal "macro", normalized.dig("scenes", 0, "shots", 0, "camera")
  end

  def test_screenwriter_recovers_scenes_from_mixed_top_level_json_values
    response = [
      { "title" => "Ignored metadata object" },
      { "data" => { "scenes" => [[{
        "heading" => "FOOSBALL TABLE",
        "objective" => "The restored player takes a place on the opposing team",
        "takes" => [{ "action" => "The metal rod slides into position", "camera" => "wide" }]
      }]] } }
    ]

    normalized = Screenwriter.normalize_generated_response(response)

    assert_equal 1, normalized["scenes"].size
    assert_equal 1, normalized.dig("scenes", 0, "shots").size
    assert_equal "The metal rod slides into position", normalized.dig("scenes", 0, "shots", 0, "visual_prompt")
  end

  def test_screenwriter_preserves_every_scene_from_a_bare_array
    response = [
      { "heading" => "THE TABLE", "action" => "The worn player is removed.", "shots" => [{ "action" => "The rod lifts" }] },
      { "heading" => "THE DUMP", "action" => "The player lands in discarded toys.", "shots" => [{ "action" => "Dust settles" }] },
      { "heading" => "THE WORKSHOP", "action" => "The craftsman restores the player.", "shots" => [{ "action" => "Red paint dries" }] }
    ]

    normalized = Screenwriter.normalize_generated_response(response)

    assert_equal 3, normalized["scenes"].size
    assert_equal ["THE TABLE", "THE DUMP", "THE WORKSHOP"], normalized["scenes"].map { |scene| scene["heading"] }
  end

  def test_screenwriter_rejects_an_empty_scene_collection_before_preflight
    assert_nil Screenwriter.normalize_generated_response({ "title" => "Empty", "scenes" => [] })
    assert_nil Screenwriter.normalize_generated_response({ "screenplay" => { "scenes" => {} } })
  end

  def test_structured_parser_preserves_scene_shots_dialogue_camera_and_duration
    prompt = <<~TEXT
      ESCENA 1: VESTIDOR - NOCHE
      Acción: Ana encuentra la camiseta sobre el banco.
      TOMA 1 - Primer plano 3s
      Cámara: macro fija
      Sus dedos levantan la insignia rota.
      ANA: No puede ser la misma.
      TOMA 2 - Plano medio 5s
      Ana mira hacia la puerta abierta.
    TEXT

    parsed = Screenwriter.parse_scenes_from_prompt(prompt)
    scene = parsed["scenes"].first

    assert_equal "VESTIDOR - NOCHE", scene["heading"]
    assert_equal 2, scene["shots"].size
    assert_equal "macro fija", scene["shots"].first["camera"]
    assert_equal 3.0, scene["shots"].first["duration"]
    assert_equal "ANA", scene["dialogue"].first["character"]
    assert_equal "No puede ser la misma.", scene["dialogue"].first["line"]
  end

  def test_structured_parser_ignores_profile_sections_and_separates_style_metadata
    prompt = <<~TEXT
      ## Character Profile
      ### Face
      This is reference-only identity material.
      ## Location Profile
      ### Platform
      A tiled underground station with green iron columns.
      ## Scene 1 - Platform
      ### Shot 1 - Wide
      A woman waits beside the train.
      [Director Style]: restrained framing and natural light
      [Narrative Context]: unrelated retrieval notes
    TEXT

    parsed = Screenwriter.parse_scenes_from_prompt(prompt)

    assert_equal 1, parsed["scenes"].size
    assert_equal 1, parsed["scenes"].first["shots"].size
    refute_includes parsed["scenes"].first["shots"].first["visual_prompt"], "reference-only"
    refute_includes parsed["scenes"].first["shots"].first["visual_prompt"], "retrieval notes"
    assert_includes parsed["scenes"].first["style_directives"].first, "restrained framing"
    assert_includes parsed.dig("source_profiles", "characters"), "reference-only identity material"
    refute_includes parsed.dig("source_profiles", "characters"), "green iron columns"
    assert_includes parsed.dig("source_profiles", "locations"), "green iron columns"
  end

  def test_offline_fallback_does_not_invent_cargo_or_science_fiction
    selection = OpenStruct.new(
      domain: :space_station,
      tone: :dark,
      seed: 4,
      protagonist_bible: "invented space courier",
      cargo_bible: "invented glowing metal container",
      base_story: { archetype: :courier, genes: [:mystery] }
    )

    screenplay = Screenwriter.generate_offline(
      selection: selection,
      prompt: "Dos hermanas preparan una receta familiar en una cocina pequeña.",
      target_duration: 20,
      max_scenes: 2
    )
    ConsistencyEnforcer.apply!(screenplay, selection)
    text = screenplay.to_json.downcase

    refute_includes text, "glowing metal container"
    refute_includes text, "space courier"
    refute_includes text, "cargo"
    assert_includes text, "receta familiar"
  end

  def test_offline_recovery_preserves_source_order_across_distinct_scenes
    prompt = [
      "A worn foosball player is removed from the table.",
      "The owner throws the player into a dump.",
      "A craftsman recognizes the toy from childhood.",
      "The craftsman repairs and repaints it.",
      "The restored player returns on the opposing team."
    ].join(" ")
    selection = OpenStruct.new(seed: 12)

    screenplay = Screenwriter.generate_offline(
      selection: selection,
      prompt: prompt,
      target_duration: 50,
      max_scenes: 5
    )
    actions = screenplay["scenes"].map { |scene| scene["action"] }

    assert_equal 5, actions.size
    assert_equal 5, actions.uniq.size
    assert_includes actions.first, "removed from the table"
    assert_includes actions.last, "opposing team"
    refute_includes screenplay.to_json.downcase, "cargo"
  end

  def test_production_bible_does_not_create_an_unmentioned_template_object
    selection = OpenStruct.new(cargo_bible: "glowing metal container")
    screenplay = {
      "scenes" => [{
        "heading" => "KITCHEN",
        "action" => "Two sisters cook together.",
        "shots" => [{ "visual_prompt" => "The sisters knead dough" }]
      }]
    }

    bible = ProductionBible.compile(
      screenplay: screenplay,
      assets: { "characters" => [], "props" => [], "locations" => [] },
      selection: selection
    )

    assert_empty bible["entities"]
  end

  def test_editor_honors_mixed_cut_and_scene_fade_from_edl
    Dir.mktmpdir("semantic_editor_test_") do |dir|
      durations = [2, 3, 2]
      paths = durations.each_with_index.map do |duration, index|
        path = File.join(dir, "clip_#{index}.mp4")
        system(
          "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
          "-f", "lavfi", "-i", "color=c=#{%w[red green blue][index]}:s=320x180:d=#{duration}",
          "-c:v", "libx264", "-pix_fmt", "yuv420p", path
        )
        path
      end
      output = File.join(dir, "assembled.mp4")
      edl = {
        "planned_duration" => 6.0,
        "entries" => [
          { "clip_id" => "1.1", "transition_out" => { "type" => "cut", "duration" => 0.0 } },
          { "clip_id" => "1.2", "transition_out" => { "type" => "fade", "duration" => 1.0 } },
          { "clip_id" => "2.1", "transition_out" => { "type" => "cut", "duration" => 0.0 } }
        ]
      }

      Editor.assemble!(shot_paths: paths, output: output, edl: edl)

      assert File.file?(output)
      assert_in_delta 6.0, Editor.probe_duration(output), 0.15
    end
  end

  def test_editor_restores_editorial_duration_from_a_short_provider_clip
    Dir.mktmpdir("semantic_editor_retime_test_") do |dir|
      source = File.join(dir, "provider_clip.mp4")
      system(
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-f", "lavfi", "-i", "color=c=teal:s=320x180:d=5",
        "-c:v", "libx264", "-pix_fmt", "yuv420p", source
      )
      output = File.join(dir, "assembled.mp4")
      edl = {
        "planned_duration" => 7.0,
        "entries" => [
          {
            "clip_id" => "1.1",
            "source_out" => 7.0,
            "transition_out" => { "type" => "cut", "duration" => 0.0 }
          }
        ]
      }

      Editor.assemble!(shot_paths: [source], output: output, edl: edl)

      assert File.file?(output)
      assert_in_delta 7.0, Editor.probe_duration(output), 0.15
    end
  end

  def test_editor_preserves_the_full_timeline_when_multiple_clips_are_retimed
    Dir.mktmpdir("semantic_editor_timeline_test_") do |dir|
      paths = %w[navy gold].each_with_index.map do |color, index|
        path = File.join(dir, "provider_clip_#{index}.mp4")
        system(
          "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
          "-f", "lavfi", "-i", "color=c=#{color}:s=320x180:d=1",
          "-c:v", "libx264", "-pix_fmt", "yuv420p", path
        )
        path
      end
      output = File.join(dir, "assembled.mp4")
      edl = {
        "planned_duration" => 2.4,
        "entries" => [
          {
            "clip_id" => "1.1", "source_out" => 1.4,
            "transition_out" => { "type" => "fade", "duration" => 0.2 }
          },
          {
            "clip_id" => "1.2", "source_out" => 1.2,
            "transition_out" => { "type" => "cut", "duration" => 0.0 }
          }
        ]
      }

      Editor.assemble!(shot_paths: paths, output: output, edl: edl)

      assert File.file?(output)
      assert_in_delta 2.4, Editor.probe_duration(output), 0.15
    end
  end

  def test_editor_caps_extreme_slow_motion_and_pads_the_remaining_hold
    filter = Editor.editorial_filter(source_duration: 5.0, target_duration: 20.0)

    assert_includes filter, "setpts=1.5*PTS"
    assert_includes filter, "tpad=stop_mode=clone:stop_duration=12.5"
  end

  def test_editor_adds_and_verifies_an_automatic_soundtrack_stream
    Dir.mktmpdir("semantic_editor_audio_test_") do |dir|
      source = File.join(dir, "silent.mp4")
      system(
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-f", "lavfi", "-i", "color=c=navy:s=320x180:d=2",
        "-c:v", "libx264", "-pix_fmt", "yuv420p", source
      )
      output = File.join(dir, "with_audio.mp4")
      edl = {
        "planned_duration" => 2.0,
        "entries" => [{ "clip_id" => "1.1", "source_out" => 2.0 }]
      }

      Editor.assemble!(
        shot_paths: [source], output: output, edl: edl,
        soundtrack_style: "ambient", require_audio: true
      )

      assert Editor.audio_stream?(output)
    end
  end
end
