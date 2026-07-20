# frozen_string_literal: true

# Deterministic narrative/editorial preflight. It reports only properties that
# can be proven from the screenplay contract; visual quality remains the job of
# the existing image/video evaluators.
class ScreenplayEvaluator
  class << self
    def evaluate(screenplay, target_duration: nil)
      issues = []
      scenes = Array(screenplay["scenes"])
      shots = scenes.flat_map { |scene| Array(scene["shots"]) }

      scenes.each do |scene|
        %w[objective conflict turn outcome continuity_in continuity_out].each do |field|
          issues << issue("critical", scene["id"], nil, "missing_scene_#{field}", "Scene lacks #{field}") if scene[field].blank?
        end
      end

      shots.each do |shot|
        %w[editorial_role purpose story_event entry_state exit_state camera].each do |field|
          issues << issue("critical", nil, shot["id"], "missing_shot_#{field}", "Shot lacks #{field}") if shot[field].blank?
        end
        if shot["duration"].to_f <= 0
          issues << issue("critical", nil, shot["id"], "invalid_duration", "Shot duration must be positive")
        end
        estimated_dialogue = shot.dig("dialogue_range", "estimated_seconds").to_f
        if estimated_dialogue.positive? && shot["duration"].to_f < estimated_dialogue
          issues << issue("critical", nil, shot["id"], "dialogue_overflow", "Dialogue cannot fit inside the planned shot")
        end
        if shot["generation_action"].to_s.length > 600
          issues << issue("critical", nil, shot["id"], "non_atomic_generation_action", "Generation action is too complex for one shot")
        elsif shot["source_visual_prompt"].to_s.length > 800
          issues << issue("warning", nil, shot["id"], "overlong_source_direction", "Long source direction was reduced to an atomic generation action")
        end
      end

      duplicate_pairs(shots).each do |previous, current|
        issues << issue("warning", nil, current["id"], "duplicate_story_event", "Repeats the event from shot #{previous['id']}")
      end

      edl = screenplay["edit_decision_list"] || EditDecisionList.compile(screenplay)
      target = target_duration || screenplay["target_duration"]
      if target.to_f.positive? && (edl["planned_duration"].to_f - target.to_f).abs > [target.to_f * 0.02, 0.25].max
        issues << issue("critical", nil, nil, "runtime_mismatch", "Planned duration does not match target")
      end

      critical = issues.count { |item| item["severity"] == "critical" }
      warnings = issues.count { |item| item["severity"] == "warning" }
      {
        "version" => "1.0",
        "ready_for_storyboard" => critical.zero?,
        "score" => [[100 - critical * 25 - warnings * 5, 0].max, 100].min,
        "scene_count" => scenes.size,
        "shot_count" => shots.size,
        "planned_duration" => edl["planned_duration"],
        "critical_count" => critical,
        "warning_count" => warnings,
        "issues" => issues
      }
    end

    private

    def duplicate_pairs(shots)
      shots.each_cons(2).select do |previous, current|
        normalized_event(previous) == normalized_event(current) && normalized_event(current).length > 20
      end
    end

    def normalized_event(shot)
      shot["story_event"].to_s.downcase.gsub(/[^\p{L}\p{N}\s]/, "").squeeze(" ").strip
    end

    def issue(severity, scene_id, shot_id, code, message)
      { "severity" => severity, "scene_id" => scene_id, "shot_id" => shot_id, "code" => code, "message" => message }
    end
  end
end
