# frozen_string_literal: true

# Adds explicit continuity state to every shot. It does not invent domain-
# specific rules: entities and constraints come from ProductionBible.
require "stable_media"

class ContinuityPlanner
  class << self
    def plan!(screenplay, production_bible)
      scenes = Array(screenplay["scenes"])
      entities = Array(production_bible&.dig("entities"))
      previous_shot = nil
      sequence = 0

      scenes.each_with_index do |scene, scene_index|
        Array(scene["shots"]).each do |shot|
          sequence += 1
          entity_ids = entities_for(shot, scene, entities)
          constraints = applicable_constraints(production_bible, entity_ids)

          shot["continuity"] = {
            "sequence" => sequence,
            "group" => "scene_#{scene_index + 1}",
            "continues_from" => previous_shot&.dig("id"),
            "required_entity_ids" => entity_ids,
            "carry_forward_entity_ids" => previous_shot ? shared_entities(previous_shot, entity_ids) : [],
            "initial_state" => initial_state(shot, previous_shot, entity_ids, scene),
            "final_state" => final_state(shot, entity_ids, scene),
            "physical_constraints" => constraints,
            "reference_image_urls" => reference_images(entity_ids, entities),
            "screen_direction" => infer_screen_direction(shot, previous_shot),
            "render_strategy" => render_strategy(entity_ids, entities)
          }
          previous_shot = shot
        end
      end

      screenplay
    end

    private

    def entities_for(shot, scene, entities)
      text = [shot["visual_prompt"], scene["action"], scene["heading"], dialogue_text(scene)].join(" ").downcase
      matched = entities.filter_map do |entity|
        name = entity["name"].to_s.downcase
        words = name.split(/[^\p{L}\p{N}]+/).reject { |word| word.length < 3 || stop_words.include?(word) }
        entity["id"] if name.present? && (text.include?(name) || words.any? { |word| text.include?(word) })
      end

      primary = entities.find { |entity| entity["is_primary"] }
      matched << primary["id"] if primary && character_action?(text) && matched.none? { |id| id.start_with?("CHARACTER_") }

      location = entities.find { |entity| entity["type"] == "location" && location_matches?(entity, scene) }
      location ||= entities.find { |entity| entity["type"] == "location" }
      matched << location["id"] if location

      matched.compact.uniq
    end

    def applicable_constraints(bible, entity_ids)
      index = ProductionBible.entity_index(bible)
      rules = entity_ids.flat_map { |id| Array(index.dig(id, "physical_constraints")) }
      rules.concat(Array(bible&.dig("global_invariants")))
      rules.map(&:to_s).map(&:strip).reject(&:empty?).uniq
    end

    def reference_images(entity_ids, entities)
      entity_ids.filter_map do |id|
        entity = entities.find { |candidate| candidate["id"] == id }
        ProductionBible.narrative_reference_images(entity || {}).find { |url| StableMedia.reference?(url) }
      end.uniq.first(9)
    end

    def initial_state(shot, previous_shot, entity_ids, scene)
      declared = shot["entry_state"]
      if declared.present?
        return {
          "status" => "declared screenplay entry state",
          "declared" => declared,
          "scene_continuity" => scene["continuity_in"],
          "source_shot_id" => previous_shot&.dig("id"),
          "entity_ids" => entity_ids
        }
      end
      return { "status" => "establish canonical entities", "entity_ids" => entity_ids } unless previous_shot

      {
        "status" => "continue from previous final frame",
        "source_shot_id" => previous_shot["id"],
        "entity_ids" => entity_ids,
        "carried_state" => previous_shot.dig("continuity", "final_state")
      }
    end

    def final_state(shot, entity_ids, scene)
      {
        "status" => "declared screenplay exit state",
        "declared" => shot["exit_state"],
        "story_event" => shot["story_event"].presence || shot["visual_prompt"].to_s,
        "scene_outcome" => scene["outcome"],
        "entity_ids" => entity_ids
      }
    end

    def shared_entities(previous_shot, current_ids)
      Array(previous_shot.dig("continuity", "required_entity_ids")) & current_ids
    end

    def render_strategy(entity_ids, entities)
      selected = entities.select { |entity| entity_ids.include?(entity["id"]) }
      characters = selected.count { |entity| entity["type"] != "location" && entity["type"] != "prop" }
      props = selected.count { |entity| entity["type"] == "prop" }

      return "keyframe_i2v" if props.positive? || selected.size > 2 || characters > 1
      return "character_r2v" if characters == 1

      "keyframe_i2v"
    end

    def infer_screen_direction(shot, previous_shot)
      declared = shot.dig("blocking", "screen_direction").to_s
      return declared if declared.present? && declared != "preserve established axis"

      text = shot["visual_prompt"].to_s.downcase
      return "left_to_right" if text.match?(/left[- ]to[- ]right|toward(?:s)? the right/)
      return "right_to_left" if text.match?(/right[- ]to[- ]left|toward(?:s)? the left/)

      previous_shot&.dig("continuity", "screen_direction") || "preserve_established_axis"
    end

    def dialogue_text(scene)
      Array(scene["dialogue"]).map { |line| "#{line['character']} #{line['line']}" }.join(" ")
    end

    def location_matches?(entity, scene)
      heading = scene["heading"].to_s.downcase
      name = entity["name"].to_s.downcase
      heading.include?(name) || name.split.any? { |word| word.length > 3 && heading.include?(word) }
    end

    def character_action?(text)
      text.match?(/\b(he|she|they|character|protagonist|hero|person|man|woman|boy|girl|creature|robot|player|actor|él|ella|personaje|protagonista)\b/i)
    end

    def stop_words
      @stop_words ||= %w[the and with from into that this character protagonist hero person player scene location object]
    end
  end
end
