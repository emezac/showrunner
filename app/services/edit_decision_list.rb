# frozen_string_literal: true

# Compiles the hierarchical screenplay into an explicit edit contract. The EDL
# is deliberately model-agnostic: video generation may change later without
# changing scene boundaries, clip order or the intended cut semantics.
class EditDecisionList
  VERSION = "1.0"

  class << self
    def compile(screenplay)
      entries = []
      timeline_cursor = 0.0
      scenes = Array(screenplay["scenes"])

      scenes.each_with_index do |scene, scene_index|
        shots = Array(scene["shots"])
        shots.each_with_index do |shot, shot_index|
          duration = positive_number(shot["duration"], 5.0)
          transition_in = if entries.empty?
                            { "type" => "cut", "duration" => 0.0, "reason" => "start of film" }
                          else
                            normalize_transition(entries.last["transition_out"])
                          end
          timeline_in = [timeline_cursor - transition_in["duration"], 0.0].max
          timeline_out = timeline_in + duration

          entries << {
            "index" => entries.size + 1,
            "clip_id" => shot["id"].to_s,
            "scene_id" => scene["id"].to_s,
            "scene_index" => scene_index + 1,
            "shot_index" => shot_index + 1,
            "scene_boundary" => shot_index.zero?,
            "editorial_role" => shot["editorial_role"].to_s,
            "purpose" => shot["purpose"].to_s,
            "source_in" => 0.0,
            "source_out" => duration.round(3),
            "timeline_in" => timeline_in.round(3),
            "timeline_out" => timeline_out.round(3),
            "transition_in" => transition_in,
            "transition_out" => normalize_transition(shot["transition_out"]),
            "audio_cues" => Array(shot["audio_cues"]),
            "dialogue_range" => shot["dialogue_range"] || {}
          }
          timeline_cursor = timeline_out
        end
      end

      {
        "version" => VERSION,
        "entries" => entries,
        "scene_count" => scenes.size,
        "clip_count" => entries.size,
        "planned_duration" => (entries.last&.dig("timeline_out") || 0.0).round(3)
      }
    end

    private

    def normalize_transition(value)
      transition = value.respond_to?(:to_h) ? value.to_h : {}
      type = (transition["type"] || transition[:type] || "cut").to_s
      duration = positive_number(transition["duration"] || transition[:duration], 0.0)
      duration = 0.0 if type == "cut" || type == "match_cut"

      {
        "type" => type,
        "duration" => duration.round(3),
        "reason" => (transition["reason"] || transition[:reason]).to_s
      }
    end

    def positive_number(value, fallback)
      number = Float(value)
      number.positive? ? number : fallback
    rescue ArgumentError, TypeError
      fallback
    end
  end
end
