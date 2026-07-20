# frozen_string_literal: true

# Upgrades arbitrary/legacy screenplays to the v3 narrative contract. It fills
# semantic gaps deterministically and allocates renderable integer clip lengths
# whose EDL duration matches the requested film duration, including overlaps.
class ScreenplayPlanner
  VERSION = "3.0"
  # Video providers currently receive integer clip durations. A one-second
  # scene overlap keeps the planned runtime exact instead of introducing
  # half-second rounding drift at render submission.
  DEFAULT_TRANSITION_DURATION = 1.0
  MIN_SHOT_DURATION = 2

  ROLE_WEIGHTS = {
    "establishing" => 1.25,
    "action" => 1.0,
    "dialogue" => 1.1,
    "reaction" => 0.7,
    "insert" => 0.65,
    "transition" => 0.8,
    "resolution" => 1.15
  }.freeze
  TRANSITION_TYPES = %w[cut fade dissolve match_cut dip_to_black wipe_left wipe_right].freeze

  class << self
    def upgrade!(screenplay, target_duration:, max_scenes: nil, seed: nil)
      screenplay = stringify_keys(screenplay || {})
      respect_existing_durations = screenplay["timing_version"].present?
      scenes = Array(screenplay["scenes"])
      scenes = scenes.first(max_scenes.to_i) if max_scenes.to_i.positive?
      screenplay["scenes"] = scenes
      screenplay["schema_version"] = VERSION
      screenplay["target_duration"] = target_duration.to_f

      enrich_scenes!(scenes, seed: seed)
      assign_transitions!(scenes)
      allocate_durations!(scenes, target_duration.to_f, respect_existing: respect_existing_durations)
      screenplay["timing_version"] = "1.0"
      screenplay["story_outline"] = normalize_outline(screenplay, scenes)
      screenplay["edit_decision_list"] = EditDecisionList.compile(screenplay)
      screenplay
    end

    private

    def enrich_scenes!(scenes, seed:)
      previous_exit = nil
      seen_scene_ids = {}
      seen_shot_ids = {}
      scenes.each_with_index do |scene, scene_index|
        candidate_scene_id = normalized_scene_id(scene["id"], scene_index)
        scene["id"] = unique_identifier(candidate_scene_id, format("scene_%02d", scene_index + 1), seen_scene_ids)
        seen_scene_ids[scene["id"]] = true
        scene["heading"] = scene["heading"].to_s.strip.presence || "SCENE #{scene_index + 1}"
        scene["action"] = scene["action"].to_s.strip
        scene["dialogue"] = Array(scene["dialogue"]).map { |line| normalize_dialogue(line) }
        scene["beat"] = scene["beat"].to_s.presence || default_beat(scene_index, scenes.size)
        scene["objective"] = scene["objective"].to_s.presence || infer_objective(scene)
        scene["conflict"] = scene["conflict"].to_s.presence || infer_conflict(scene)
        scene["turn"] = scene["turn"].to_s.presence || infer_turn(scene)
        scene["outcome"] = scene["outcome"].to_s.presence || infer_outcome(scene)
        scene["emotional_state_in"] ||= { "beat" => scene["beat"], "status" => "entering scene" }
        scene["emotional_state_out"] ||= { "beat" => scene["beat"], "status" => scene["outcome"] }
        scene["continuity_in"] ||= previous_exit || { "status" => "establish scene geography and entities" }

        shots = Array(scene["shots"])
        shots = [fallback_shot(scene)] if shots.empty?
        scene["shots"] = shots
        enrich_shots!(scene, scene_index, seed: seed, seen_ids: seen_shot_ids)
        scene["continuity_out"] ||= scene["shots"].last["exit_state"]
        previous_exit = scene["continuity_out"]
      end
    end

    def enrich_shots!(scene, scene_index, seed:, seen_ids:)
      previous_exit = scene["continuity_in"]
      scene["shots"].each_with_index do |shot, shot_index|
        candidate_id = normalized_shot_id(shot["id"], scene_index, shot_index)
        shot["id"] = unique_identifier(candidate_id, "#{scene_index + 1}.#{shot_index + 1}", seen_ids)
        seen_ids[shot["id"]] = true
        shot["beat"] = shot["beat"].to_s.presence || scene["beat"]
        shot["camera"] = shot["camera"].to_s.presence || fallback_camera(shot_index, seed)
        shot["visual_prompt"] = shot["visual_prompt"].to_s.presence || scene["action"]
        shot["editorial_role"] = shot["editorial_role"].to_s.presence || infer_role(shot, shot_index, scene["shots"].size)
        shot["story_event"] = atomic_text(shot["story_event"].to_s.presence || shot["visual_prompt"].to_s)
        shot["purpose"] = shot["purpose"].to_s.presence || infer_purpose(shot)
        shot["entry_state"] ||= previous_exit
        shot["exit_state"] ||= {
          "status" => "result of shot action",
          "event" => shot["story_event"],
          "preserve_for_next_shot" => true
        }
        shot["blocking"] ||= { "screen_direction" => "preserve established axis" }
        shot["audio_cues"] = Array(shot["audio_cues"])
        shot["dialogue_range"] ||= {}
        shot["mode"] ||= "t2v"
        previous_exit = shot["exit_state"]
      end
      assign_dialogue_range!(scene)
    end

    def assign_transitions!(scenes)
      scenes.each_with_index do |scene, scene_index|
        shots = Array(scene["shots"])
        shots.each_with_index do |shot, shot_index|
          if valid_transition?(shot["transition_out"])
            shot["transition_out"] = normalize_transition(shot["transition_out"])
            next
          end

          shot["transition_out"] = if scene_index == scenes.size - 1 && shot_index == shots.size - 1
                                     { "type" => "cut", "duration" => 0.0, "reason" => "end of film" }
                                   elsif shot_index == shots.size - 1
                                     {
                                       "type" => "fade",
                                       "duration" => DEFAULT_TRANSITION_DURATION,
                                       "reason" => "scene boundary"
                                     }
                                   else
                                     {
                                       "type" => "cut",
                                       "duration" => 0.0,
                                       "reason" => "preserve action and dialogue continuity"
                                     }
                                   end
        end
      end
    end

    def allocate_durations!(scenes, target_duration, respect_existing: false)
      shots = scenes.flat_map { |scene| Array(scene["shots"]) }
      return if shots.empty?

      overlap = shots.sum { |shot| transition_duration(shot["transition_out"]) }
      render_total = [(target_duration + overlap).round, shots.size].max
      minimum = render_total >= shots.size * MIN_SHOT_DURATION ? MIN_SHOT_DURATION : 1
      remaining = render_total - (shots.size * minimum)
      weights = shots.map { |shot| duration_weight(shot, respect_existing: respect_existing) }
      weight_total = weights.sum
      raw_extras = weights.map { |weight| remaining.positive? ? (remaining * weight / weight_total) : 0.0 }
      extras = raw_extras.map(&:floor)
      remainder = remaining - extras.sum
      ranked = raw_extras.each_with_index.sort_by { |value, index| [-(value - value.floor), index] }
      remainder.times { |index| extras[ranked[index][1]] += 1 }

      shots.each_with_index { |shot, index| shot["duration"] = minimum + extras[index] }
      enforce_dialogue_minimums!(shots, minimum)
      scenes.each do |scene|
        scene_shots = Array(scene["shots"])
        scene["duration_budget"] = (
          scene_shots.sum { |shot| shot["duration"].to_f } -
          scene_shots.sum { |shot| transition_duration(shot["transition_out"]) }
        ).round(3)
      end
    end

    def normalize_outline(screenplay, scenes)
      raw_outline = screenplay["story_outline"]
      current = raw_outline.is_a?(Hash) ? stringify_keys(raw_outline) : {}
      current["premise"] = current["premise"].to_s.presence || scenes.first&.dig("action").to_s
      current["structure"] = current["structure"].to_s.presence || infer_structure(scenes)
      current["central_question"] = current["central_question"].to_s.presence || scenes.first&.dig("objective").to_s
      current["resolution"] = current["resolution"].to_s.presence || scenes.last&.dig("outcome").to_s
      current["causal_chain"] = scenes.map do |scene|
        { "scene_id" => scene["id"], "turn" => scene["turn"], "outcome" => scene["outcome"] }
      end
      current
    end

    def infer_structure(scenes)
      beats = scenes.map { |scene| scene["beat"].to_s }
      return "discovery" if beats.any? { |beat| beat.match?(/mystery|revelation|discover/) }
      return "escalation_and_payoff" if beats.any? { |beat| beat.match?(/danger|climax|escalation/) }

      "objective_obstacle_resolution"
    end

    def infer_objective(scene)
      text = atomic_text(scene["action"].to_s)
      text.present? ? "Advance the scene by accomplishing: #{text}" : "Establish a concrete change"
    end

    def infer_conflict(scene)
      "The intended action meets resistance appropriate to the #{scene['beat']} beat"
    end

    def infer_turn(scene)
      "New action or information changes the situation: #{atomic_text(scene['action'].to_s)}"
    end

    def infer_outcome(scene)
      "The visible result of the scene action persists into the next scene"
    end

    def infer_role(shot, index, count)
      text = [shot["camera"], shot["visual_prompt"]].join(" ").downcase
      return "establishing" if index.zero?
      return "resolution" if index == count - 1
      return "insert" if text.match?(/insert|detail|macro|extreme close|detalle/)
      return "reaction" if text.match?(/reaction|reacts|reacc|expression|rostro/)
      return "dialogue" if text.match?(/speaks|says|dialogue|habla|dice/)

      "action"
    end

    def infer_purpose(shot)
      labels = {
        "establishing" => "Establish geography, subjects and the initial state",
        "reaction" => "Reveal the subject's response to the preceding event",
        "insert" => "Communicate a decisive object or story detail",
        "dialogue" => "Deliver dialogue while preserving eyelines and performance",
        "resolution" => "Show the result that must carry into the next scene",
        "transition" => "Bridge time, place or narrative state",
        "action" => "Advance one atomic visible action"
      }
      labels.fetch(shot["editorial_role"], labels["action"])
    end

    def duration_weight(shot, respect_existing: false)
      existing = shot["duration"].to_f
      weight = if respect_existing && existing.positive?
                 existing
               else
                 ROLE_WEIGHTS.fetch(shot["editorial_role"], 1.0)
               end
      words = shot.dig("dialogue_range", "word_count").to_i
      weight += [words / 12.0, 1.5].min if words.positive?
      weight += 0.2 if shot["beat"].to_s.match?(/climax|aftermath|revelation/)
      weight
    end

    def enforce_dialogue_minimums!(shots, minimum)
      shots.each do |shot|
        required = shot.dig("dialogue_range", "estimated_seconds").to_f.ceil
        next unless required.positive? && shot["duration"].to_i < required

        needed = required - shot["duration"].to_i
        donors = shots.reject { |candidate| candidate.equal?(shot) }.sort_by { |candidate| -candidate["duration"].to_i }
        donors.each do |donor|
          transferable = [donor["duration"].to_i - minimum, needed].min
          next unless transferable.positive?

          donor["duration"] -= transferable
          shot["duration"] += transferable
          needed -= transferable
          break if needed.zero?
        end
      end
    end

    def assign_dialogue_range!(scene)
      dialogue = Array(scene["dialogue"])
      return if dialogue.empty?

      shots = Array(scene["shots"])
      return if shots.any? { |shot| shot["dialogue_range"].present? }

      words = dialogue.sum { |line| line["line"].to_s.split.size }
      target = shots.find { |shot| shot["editorial_role"] == "dialogue" } || shots.first
      target["dialogue_range"] = {
        "line_indexes" => (0...dialogue.size).to_a,
        "word_count" => words,
        "estimated_seconds" => (words / 2.5 + 0.8).round(2)
      }
    end

    def default_beat(index, count)
      curve = %w[setup development complication decision resolution]
      curve[((index.to_f / [count - 1, 1].max) * (curve.size - 1)).round]
    end

    def fallback_camera(index, seed)
      cameras = %w[wide medium close_up tracking]
      cameras[(index + seed.to_i) % cameras.size]
    end

    def fallback_shot(scene)
      { "visual_prompt" => scene["action"].presence || scene["heading"], "camera" => "wide" }
    end

    def normalize_dialogue(line)
      data = line.respond_to?(:to_h) ? stringify_keys(line) : { "line" => line.to_s }
      { "character" => data["character"].to_s, "line" => data["line"].to_s }
    end

    def normalized_scene_id(value, index)
      candidate = value.to_s
      candidate.match?(/\Ascene_/i) ? candidate : format("scene_%02d", index + 1)
    end

    def normalized_shot_id(value, scene_index, shot_index)
      candidate = value.to_s
      candidate.present? ? candidate : "#{scene_index + 1}.#{shot_index + 1}"
    end

    def unique_identifier(candidate, fallback, seen)
      return candidate unless seen[candidate]
      return fallback unless seen[fallback]

      suffix = 2
      suffix += 1 while seen["#{fallback}_#{suffix}"]
      "#{fallback}_#{suffix}"
    end

    def atomic_text(value, max_chars: 420)
      text = value.to_s.gsub(/\*\*|__|#+/, "").gsub(/\s+/, " ").strip
      return text if text.length <= max_chars

      sentences = text.split(/(?<=[.!?])\s+/)
      candidate = [sentences.first, sentences.last].compact.uniq.join(" ")
      candidate = text if candidate.blank?
      candidate[0, max_chars].sub(/\s+\S*\z/, "").strip
    end

    def valid_transition?(value)
      return false unless value.respond_to?(:to_h)

      transition = value.to_h
      transition["type"].present? || transition[:type].present?
    end

    def normalize_transition(value)
      transition = value.to_h
      type = (transition["type"] || transition[:type]).to_s
      type = "cut" unless TRANSITION_TYPES.include?(type)
      duration = if %w[cut match_cut].include?(type)
                 0.0
               else
                   requested = Float(transition["duration"] || transition[:duration] || DEFAULT_TRANSITION_DURATION)
                   [[requested.round, 1].max, 2].min.to_f
                 end
      {
        "type" => type,
        "duration" => duration,
        "reason" => (transition["reason"] || transition[:reason]).to_s
      }
    rescue ArgumentError, TypeError
      { "type" => "cut", "duration" => 0.0, "reason" => "invalid transition replaced" }
    end

    def transition_duration(value)
      transition = value.respond_to?(:to_h) ? value : {}
      type = (transition["type"] || transition[:type]).to_s
      return 0.0 if type == "cut" || type == "match_cut"

      Float(transition["duration"] || transition[:duration] || 0.0)
    rescue ArgumentError, TypeError
      0.0
    end

    def stringify_keys(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, item), output| output[key.to_s] = stringify_keys(item) }
      when Array
        value.map { |item| stringify_keys(item) }
      else
        value
      end
    end
  end
end
