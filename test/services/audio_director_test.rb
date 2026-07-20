# frozen_string_literal: true

require "test_helper"
require_relative "../../app/services/audio_director"

class AudioDirectorTest < ActiveSupport::TestCase
  test "explicit voice derives narration from approved scene actions when dialogue is absent" do
    screenplay = {
      "scenes" => [
        { "action" => "A worn foosball player dreams of becoming the best.", "dialogue" => [] },
        { "action" => "A craftsman restores him and returns him to the table.", "dialogue" => [] }
      ]
    }

    resolution = AudioDirector.resolve_narration(screenplay)

    assert_equal "approved_scene_actions", resolution["source"]
    assert_equal(
      "A worn foosball player dreams of becoming the best. A craftsman restores him and returns him to the table.",
      resolution["text"]
    )
  end

  test "existing spoken text remains authoritative over action-derived narration" do
    screenplay = {
      "narration" => "The old champion waits.",
      "scenes" => [{ "action" => "A different technical action description.", "dialogue" => [] }]
    }

    resolution = AudioDirector.resolve_narration(screenplay)

    assert_equal "screenplay_spoken_text", resolution["source"]
    assert_equal "The old champion waits.", resolution["text"]
  end

  test "selected narration still rejects a screenplay with no narratable content" do
    error = assert_raises(AudioDirector::ConfigurationError) do
      AudioDirector.prepare!(
        screenplay: { "scenes" => [{ "heading" => "EMPTY" }] },
        direction: { "music_style" => "ambient", "voice_style" => "male_deep" },
        output_dir: "/tmp"
      )
    end

    assert_includes error.message, "no spoken text or narrative scene actions"
  end

  test "no narration selection does not derive or synthesize a voice track" do
    plan = AudioDirector.prepare!(
      screenplay: { "scenes" => [{ "action" => "A visible action." }] },
      direction: { "music_style" => "ambient", "voice_style" => "none" },
      output_dir: "/tmp"
    )

    assert_equal "none", plan["narration_source"]
    assert_equal "", plan["narration_text"]
    assert_nil plan["voice_track"]
    assert_nil plan["speech_rate_wpm"]
  end

  test "speech rate fits source-locked narration inside the planned cut" do
    narration = Array.new(179, "word").join(" ")

    assert_equal 217, AudioDirector.speech_rate_for(narration, target_duration: 55)
    assert_equal 180, AudioDirector.speech_rate_for(narration)
    assert_equal 260, AudioDirector.speech_rate_for(Array.new(500, "word").join(" "), target_duration: 30)
  end
end
