# frozen_string_literal: true

require_relative "scale_contract_resolver"
require "stable_media"

# Compiles the assets extracted from an arbitrary screenplay into a stable,
# machine-readable visual contract. Nothing in this class is tied to a genre or
# a particular story: it treats humans, creatures, props and locations as
# entities with immutable traits, scale anchors and physical constraints.
class ProductionBible
  VERSION = "1.0"

  GLOBAL_INVARIANTS = [
    "preserve every entity's identity, materials, colors and proportions",
    "preserve relative scale between characters, props and locations",
    "objects persist between adjacent shots unless the screenplay explicitly removes them",
    "motion must respect contact, gravity, inertia, joints and declared attachments",
    "never duplicate, merge, replace or spontaneously transform a canonical entity"
  ].freeze

  GLOBAL_NEGATIVE_CONSTRAINTS = [
    "identity drift",
    "different face",
    "different clothing",
    "color change",
    "material change",
    "scale change",
    "duplicate subject",
    "missing required object",
    "morphing anatomy",
    "floating without physical cause",
    "teleportation",
    "style shift",
    "unrequested visible text",
    "typography",
    "captions",
    "labels",
    "logos",
    "watermarks",
    "measurement rulers",
    "calibration grids",
    "technical diagrams",
    "interface overlays"
  ].freeze

  CONSISTENCY_POLICY = {
    "priority" => "canonical truth overrides cinematic interpretation",
    "hard_locks" => [
      "character identity, face, age, body proportions and wardrobe",
      "prop identity, material, color, dimensions and persistent damage",
      "relative physical scale between every recurring entity",
      "declared attachments, articulation limits, contact, gravity and inertia",
      "location architecture, spatial topology and persistent object state",
      "entry/exit state continuity and causal order between shots and scenes"
    ],
    "creative_freedoms" => [
      "lens, camera height and camera movement that do not falsify physical scale",
      "composition and depth of field that keep required scale anchors legible",
      "lighting and color grade that preserve canonical colors and materials",
      "editorial rhythm, transitions, music and sound design"
    ],
    "variant_rule" => "identity, wardrobe, damage, attachment or scale changes require an explicit separately profiled canonical variant"
  }.freeze

  class << self
    def compile(screenplay:, assets:, selection: nil, original_prompt: nil)
      ScaleContractResolver.apply!(assets || {}, source_prompt: original_prompt)
      assets = normalize_assets(assets)
      entities = []

      assets["characters"].each_with_index do |asset, index|
        entities << character_entity(asset, index)
      end
      assets["props"].each_with_index do |asset, index|
        entities << prop_entity(asset, index)
      end
      assets["locations"].each_with_index do |asset, index|
        entities << location_entity(asset, index)
      end

      if assets["props"].empty? && story_object_mentioned?(screenplay, selection)
        entities << fallback_story_object(selection.cargo_bible)
      end

      inferred_rules = normalize_list(assets["world_rules"])

      {
        "version" => VERSION,
        "source_prompt" => original_prompt.to_s,
        "source_profiles" => screenplay["source_profiles"],
        "entities" => entities,
        "global_invariants" => (GLOBAL_INVARIANTS + inferred_rules).uniq,
        "negative_constraints" => GLOBAL_NEGATIVE_CONSTRAINTS.dup,
        "consistency_policy" => CONSISTENCY_POLICY.deep_dup,
        "scale_anchors" => entities.filter_map { |entity| scale_anchor(entity) },
        "scene_count" => Array(screenplay["scenes"]).size
      }
    end

    def entity_index(bible)
      Array(bible&.dig("entities")).index_by { |entity| entity["id"].to_s }
    end

    def prompt_contract(bible, entity_ids)
      index = entity_index(bible)
      entities = Array(entity_ids).filter_map { |id| index[id.to_s] }
      return "" if entities.empty?

      entities.map do |entity|
        traits = Array(entity["immutable_traits"]).reject(&:blank?).join("; ")
        physics = Array(entity["physical_constraints"]).reject(&:blank?).join("; ")
        agency = Array(entity["allowed_attached_motion"]).reject(&:blank?).join("; ")
        parts = ["#{entity['id']} #{entity['name']}: #{entity['canonical_descriptor']}"]
        parts << "immutable: #{traits}" if traits.present?
        parts << "physics: #{physics}" if physics.present?
        parts << "attached agency: #{agency}" if agency.present?
        parts.join("; ")
      end.join(" | ")
    end

    def negative_prompt(bible, entity_ids = nil)
      index = entity_index(bible)
      entities = if entity_ids
                   Array(entity_ids).filter_map { |id| index[id.to_s] }
                 else
                   index.values
                 end
      constraints = Array(bible&.dig("negative_constraints")).dup
      constraints.concat(entities.flat_map { |entity| Array(entity["forbidden_mutations"]) })
      constraints.map(&:to_s).map(&:strip).reject(&:empty?).uniq.join(", ")
    end

    def narrative_reference_images(entity)
      source = entity.to_h.with_indifferent_access
      qa = (Array(source["qa_reference_images"]) + Array(source["stable_qa_reference_images"])).map(&:to_s)
      scale = [source["scale_calibration_image_url"], source["stable_scale_calibration_image_url"]]
        .compact.map(&:to_s)
      candidates = Array(source["reference_images"]).select { |url| StableMedia.reference?(url) } +
        Array(source["stable_reference_images"]).select { |url| StableMedia.reference?(url) }
      candidates.uniq.reject do |url|
        qa.include?(url.to_s) || scale.include?(url.to_s)
      end
    end

    private

    def story_object_mentioned?(screenplay, selection)
      return false unless selection&.respond_to?(:cargo_bible)

      descriptor = selection.cargo_bible.to_s.strip
      return false if descriptor.empty?

      story_text = Array(screenplay["scenes"]).flat_map do |scene|
        [scene["heading"], scene["action"], *Array(scene["shots"]).map { |shot| shot["visual_prompt"] }]
      end.compact.join(" ").downcase
      meaningful_words = descriptor.downcase.scan(/[\p{L}\p{N}]+/).reject do |word|
        word.length < 4 || %w[with that from this object cargo carga para como una uno].include?(word)
      end
      meaningful_words.any? { |word| story_text.include?(word) }
    end

    def normalize_assets(assets)
      source = assets.respond_to?(:to_h) ? assets.to_h : {}
      {
        "characters" => Array(source["characters"] || source[:characters]),
        "props" => Array(source["props"] || source[:props]),
        "locations" => Array(source["locations"] || source[:locations]),
        "world_rules" => source["world_rules"] || source[:world_rules]
      }
    end

    def character_entity(asset, index)
      data = stringify(asset)
      entity_type = data["entity_type"].presence || "character"
      descriptor = [data["physical_description"], data["wardrobe"], data["style"]].compact_blank.join(", ")
      descriptor = data["visual_prompt"].to_s if descriptor.blank?

      base_entity(data, "CHARACTER_#{index + 1}", entity_type, descriptor).merge(
        "immutable_traits" => normalize_list(data["immutable_traits"]) +
          normalize_list(data["identity_anchors"]),
        "physical_constraints" => normalize_list(data["physical_constraints"]),
        "forbidden_mutations" => normalize_list(data["forbidden_mutations"]) +
          ["different facial identity", "different body proportions", "different wardrobe"],
        "is_primary" => index.zero?
      )
    end

    def prop_entity(asset, index)
      data = stringify(asset)
      descriptor = [
        data["description"], data["color"], data["material"], data["dimensions"],
        normalize_list(data["distinctive_features"]).join(", ")
      ].compact_blank.join(", ")
      descriptor = data["visual_prompt"].to_s if descriptor.blank?

      base_entity(data, "PROP_#{index + 1}", "prop", descriptor).merge(
        "immutable_traits" => normalize_list(data["immutable_traits"]) +
          [data["color"], data["material"], data["dimensions"]].compact_blank,
        "physical_constraints" => normalize_list(data["physical_constraints"]) +
          normalize_list(data["behavior_constraints"]),
        "forbidden_mutations" => normalize_list(data["forbidden_mutations"]) +
          ["different color", "different material", "different size", "different design"]
      )
    end

    def location_entity(asset, index)
      data = stringify(asset)
      descriptor = [data["description"], data["lighting"], data["atmosphere"]].compact_blank.join(", ")
      descriptor = data["visual_prompt"].to_s if descriptor.blank?

      base_entity(data, "LOCATION_#{index + 1}", "location", descriptor).merge(
        "immutable_traits" => normalize_list(data["immutable_traits"]),
        "physical_constraints" => normalize_list(data["physical_constraints"]),
        "forbidden_mutations" => normalize_list(data["forbidden_mutations"]) +
          ["different architecture", "unmotivated time-of-day change", "different spatial layout"]
      )
    end

    def base_entity(data, fallback_id, type, descriptor)
      durable_narrative = Array(data["stable_reference_images"]).select { |url| StableMedia.local_available?(url) }
      durable_narrative = [data["stable_image_url"]].select { |url| StableMedia.local_available?(url) } if durable_narrative.empty?
      narrative_references = Array(data["reference_images"]).presence || [data["image_url"]].compact
      durable_qa = (Array(data["stable_qa_reference_images"]) + [data["stable_scale_calibration_image_url"]])
        .compact.select { |url| StableMedia.local_available?(url) }.uniq
      qa_references = (Array(data["qa_reference_images"]) + [data["scale_calibration_image_url"]]).compact.uniq
      narrative_references = narrative_references.reject { |url| qa_references.include?(url) }
      if ScaleContractResolver::TECHNICAL_REFERENCE_PATTERN.match?(data["visual_prompt"].to_s)
        # Legacy manifests used the calibration sheet as image_url. Never let
        # an unclassified technical plate reach T2I/R2V again.
        qa_references = (qa_references + narrative_references).uniq
        durable_qa = (durable_qa + durable_narrative).uniq
        narrative_references = []
        durable_narrative = []
      end
      {
        "id" => data["canonical_id"].presence || fallback_id,
        "asset_id" => data["id"],
        "type" => type,
        "name" => data["name"].presence || fallback_id.titleize,
        "canonical_descriptor" => descriptor,
        "scale_reference" => data["scale_reference"].presence || "preserve approved relative scale",
        "reference_images" => narrative_references,
        "stable_reference_images" => durable_narrative,
        "qa_reference_images" => qa_references,
        "stable_qa_reference_images" => durable_qa,
        "scale_calibration_image_url" => data["scale_calibration_image_url"],
        "stable_scale_calibration_image_url" => data["stable_scale_calibration_image_url"],
        "agency_mode" => data["agency_mode"],
        "allowed_attached_motion" => normalize_list(data["allowed_attached_motion"]),
        "visual_prompt" => data["visual_prompt"].to_s
      }
    end

    def fallback_story_object(description)
      {
        "id" => "STORY_OBJECT_1",
        "asset_id" => nil,
        "type" => "prop",
        "name" => "Primary story object",
        "canonical_descriptor" => description.to_s,
        "scale_reference" => "preserve the same approved size relative to the protagonist",
        "reference_images" => [],
        "visual_prompt" => description.to_s,
        "immutable_traits" => [description.to_s],
        "physical_constraints" => [],
        "forbidden_mutations" => ["different color", "different material", "different size", "different design"]
      }
    end

    def scale_anchor(entity)
      value = entity["scale_reference"].to_s.strip
      return if value.empty?

      { "entity_id" => entity["id"], "rule" => value }
    end

    def normalize_list(value)
      case value
      when Array then value
      when String then value.split(/[;\n]/)
      else []
      end.map(&:to_s).map(&:strip).reject(&:empty?).uniq
    end

    def stringify(value)
      value.respond_to?(:stringify_keys) ? value.stringify_keys : value.to_h.transform_keys(&:to_s)
    end
  end
end
