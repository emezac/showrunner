# frozen_string_literal: true

require "digest"
require_relative "production_bible"
require "stable_media"

# Builds one neutral, scale-readable composition anchor per complex scene and
# prepends it to every shot's references. Final frames may vary camera and
# lighting, but all begin from the same approved spatial/scale relationship.
class ContinuityPlatePlanner
  class << self
    def generate!(screenplay:, production_bible:, client:, ledger:, dry_run: false, shot_ids: nil,
                  cancellation_check: nil)
      index = ProductionBible.entity_index(production_bible)
      wanted = Array(shot_ids).map(&:to_s)
      errors = []
      generated = []

      Array(screenplay["scenes"]).each_with_index do |scene, scene_index|
        cancellation_check&.call
        shots = Array(scene["shots"])
        targets = wanted.any? ? shots.select { |shot| wanted.include?(shot["id"].to_s) } : shots
        next if targets.empty?

        entity_ids = targets.flat_map { |shot| Array(shot.dig("continuity", "required_entity_ids")) }.uniq
        entities = entity_ids.filter_map { |id| index[id.to_s] }
        next unless required?(entities)

        references = ordered_references(entities)
        prompt = plate_prompt(scene, entities, production_bible)
        digest = Digest::SHA256.hexdigest(JSON.generate([prompt, references]))
        existing = scene["continuity_plate"].to_h
        existing_url = if StableMedia.local_available?(existing["stable_image_url"])
                         existing["stable_image_url"]
                       else
                         existing["image_url"]
                       end

        url = if existing["contract_digest"] == digest && remote_url?(existing_url)
                existing_url
              elsif dry_run
                "/placeholders/continuity_plate_#{scene_index + 1}.png"
              else
                cancellation_check&.call
                result = client.submit_with_retries(
                  prompt: prompt,
                  mode: :t2i,
                  reference_image_urls: references
                )
                ledger[:video_credits_used] = ledger[:video_credits_used].to_i + 1
                unless result.succeeded? && remote_url?(result.image_url)
                  errors << "Scene #{scene['id'] || scene_index + 1} did not return a continuity plate"
                  next
                end
                generated << scene["id"].to_s
                result.image_url
              end

        scene["continuity_plate"] = {
          "image_url" => url,
          "contract_digest" => digest,
          "entity_ids" => entity_ids,
          "prompt" => prompt,
          "status" => remote_url?(url) ? "ready" : "dry_run"
        }
        next unless remote_url?(url)

        targets.each do |shot|
          canonical = Array(shot.dig("continuity", "reference_image_urls"))
          shot["continuity"]["reference_image_urls"] = ([url] + canonical).uniq.first(9)
          shot["continuity"]["continuity_plate_url"] = url
        end
      rescue ActiveRecord::RecordNotFound
        raise
      rescue StandardError => e
        ledger[:video_credits_used] = ledger[:video_credits_used].to_i + 1 unless dry_run
        errors << "Scene #{scene['id'] || scene_index + 1}: #{e.message}"
      end

      { "errors" => errors, "generated_scene_ids" => generated }
    end

    private

    def required?(entities)
      non_locations = entities.reject { |entity| entity["type"] == "location" }
      return true if non_locations.size > 1

      entities.any? do |entity|
        meaningful_scale_reference?(entity["scale_reference"]) ||
          Array(entity["physical_constraints"]).join(" ").match?(/fixed|attached|mounted|scale|dimension|size|fijad|montad|escala|tamaño/i)
      end
    end

    def meaningful_scale_reference?(value)
      text = value.to_s.squish
      text.present? && text != "preserve approved relative scale"
    end

    def ordered_references(entities)
      # Environment/props establish world scale before identity references.
      entities.sort_by { |entity| entity["type"] == "location" ? 0 : (entity["type"] == "prop" ? 1 : 2) }
        .filter_map do |entity|
          ProductionBible.narrative_reference_images(entity).find { |url| remote_url?(url) }
        end.uniq.first(9)
    end

    def plate_prompt(scene, entities, bible)
      entity_contract = entities.map do |entity|
        "#{entity['id']} #{entity['name']}: #{entity['canonical_descriptor']}; scale=#{entity['scale_reference']}; " \
          "physics=#{Array(entity['physical_constraints']).join('; ')}"
      end.join(" | ")
      hard_locks = Array(bible&.dig("consistency_policy", "hard_locks")).join("; ")
      <<~PROMPT.squish
        CANONICAL SCENE MASTER — INTERNAL COMPOSITION ANCHOR, NOT A HERO SHOT.
        Scene: #{scene['heading']}. Show the complete recurring subjects, props
        and environment together in one neutral wide orthographic composition.
        Preserve exact identity, materials, colors, body proportions, attachments,
        spatial topology and relative physical scale. Put comparable entities on
        a shared depth plane with visible environmental scale witnesses. No forced
        perspective, foreground enlargement, dramatic low angle, crop, portrait
        emphasis or depth-of-field blur. This must be a clean narrative-safe
        image: no title, text, letters, labels, ruler, grid, chart, diagram,
        caption, logo, watermark or interface overlay. Hard locks: #{hard_locks}. Canonical
        entities: #{entity_contract}
      PROMPT
    end

    def remote_url?(value)
      StableMedia.reference?(value)
    end
  end
end
