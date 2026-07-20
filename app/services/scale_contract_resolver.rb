# frozen_string_literal: true

# Reconciles relative scale across independently generated character, prop and
# environment profiles. The rules are class-based, so they work for humans,
# miniatures, animals, vehicles, products and arbitrary fictional entities.
class ScaleContractResolver
  MINIATURE_PATTERN = /foosball|futbol[ií]n|table.?football|figurine|miniature|toy|doll|muñec|maqueta|scale model|plastic player/i
  PEER_PATTERN = /player figures?|figurines?|miniatures?|toy figures?|dolls?|figuras?(?: de)? jugadores?|muñecos?/i
  MEASUREMENT_PATTERN = /(?:approximately|approx\.?|about|aproximadamente|entre)?\s*\d+(?:\.\d+)?\s*(?:-|–|to|a)\s*\d+(?:\.\d+)?\s*(?:cm|mm|inches?|pulgadas?)|\d+(?:\.\d+)?\s*(?:cm|mm|inches?|pulgadas?)/i
  # `MINIATURE CLASS LOCK` is also part of the clean narrative-reference
  # prompt. Treating that phrase alone as a technical plate caused every
  # regenerated miniature portrait to be moved into QA-only references and
  # cleared from `image_url` during the next ProductionBible compilation.
  TECHNICAL_REFERENCE_PATTERN = /
    ABSOLUTE\s+MINIATURE\s+SCALE\s+CALIBRATION\s+SHEET |
    SCALE\s+CALIBRATION\s*: |
    technical\s+orthographic\s+lineup |
    visible\s+ruler |
    measurement\s+grid |
    exactly\s+equal\s+pixel\s+height
  /ix

  class << self
    def apply!(assets, source_prompt: nil)
      original_assets = assets
      assets = assets.with_indifferent_access
      context = [source_prompt, *Array(assets["props"]).map { |item| item.to_h.values.join(" ") },
                 *Array(assets["locations"]).map { |item| item.to_h.values.join(" ") }].compact.join(" ")
      changed_ids = []

      Array(assets["characters"]).each_with_index do |raw, index|
        character = raw.with_indifferent_access
        recover_misclassified_narrative_reference!(character)
        descriptor = [character["entity_type"], character["physical_description"], character["visual_prompt"]].join(" ")
        next unless descriptor.match?(MINIATURE_PATTERN)

        peer_matches = []
        context.to_enum(:scan, PEER_PATTERN).each { peer_matches << Regexp.last_match }
        candidates = peer_matches.filter_map do |match|
          start_at = [match.begin(0) - 120, 0].max
          window = context[start_at, 520]
          measures = window.scan(MEASUREMENT_PATTERN)
          measure = measures.find { |item| item.match?(/-|–|\bto\b|\ba\b/i) } || measures.first
          [match[0], measure] if measure
        end
        chosen = candidates.find { |_peer, measure| measure.match?(/-|–|\bto\b|\ba\b/i) } || candidates.first
        peer = chosen&.first || peer_matches.first&.[](0) || "other recurring figures of the same class"
        measurement = chosen&.last
        rule = [
          "MINIATURE CLASS LOCK: exactly the same physical height and body scale as #{peer}",
          measurement && "canonical height #{measurement}",
          "when standing on the same depth plane it must occupy comparable height to its peers",
          "camera framing may make it feel imposing but must never change its physical size",
          "never human-sized, giant, mascot-sized, oversized or larger than same-class peer figures"
        ].compact.join("; ")
        mounted_figure = descriptor.match?(/foosball|futbol[ií]n|table.?football/i)
        mounting = if mounted_figure
                     "Keep all three figures mounted at their canonical points on parallel metal control rods"
                   else
                     "Place all three figures on one shared neutral baseline"
                   end
        source_identity = character["source_identity_prompt"].presence || character["visual_prompt"].to_s
          .sub(/\AABSOLUTE MINIATURE SCALE CALIBRATION SHEET\s*[—-]\s*FIRST PRIORITY.*?SOURCE IDENTITY:\s*/im, "")
          .sub(/\ACANONICAL NARRATIVE CHARACTER REFERENCE\s*[—-]\s*GENERATION SAFE\.\s*/i, "")
          .sub(/\.\s*MINIATURE CLASS LOCK:.*\z/im, "")
          .sub(/\s+SCALE CALIBRATION:.*\z/m, "")
          .sub(/\ACANONICAL SOURCE-LOCKED full-body reference of [^:]+:\s*/i, "")
          .squish.first(1_900)
        reference_instruction = [
          "ABSOLUTE MINIATURE SCALE CALIBRATION SHEET — FIRST PRIORITY",
          rule,
          mounting,
          "technical orthographic lineup, not a portrait and not a hero shot; no forced perspective and no foreground enlargement",
          "show three complete uncropped same-class figures side by side at exactly the same camera depth and on one shared baseline",
          "the protagonist and both peers must have exactly equal pixel height, equal body width, equal rod-to-head proportions and equal distance to camera",
          "include a visible ruler or measurement grid",
          "all three figures occupy exactly the same number of vertical pixels; the center protagonist must not be taller, wider, closer to camera or more massive than either peer",
          "SOURCE IDENTITY: #{source_identity}"
        ].join(". ")

        # Calibration sheets are useful QA evidence, but are poisonous as
        # image/video generation references: image models reproduce their
        # rulers, labels and layout in the final film. Keep the technical plate
        # in a separate reference role and give narrative generation a clean,
        # single-subject reference prompt.
        narrative_instruction = [
          "CANONICAL NARRATIVE CHARACTER REFERENCE — GENERATION SAFE",
          source_identity,
          rule,
          mounted_figure && "show the complete figure mechanically mounted on one clean metal rod segment at the canonical attachment point",
          "single complete subject only, neutral full-body view, plain seamless background, even cinematic-neutral light",
          "preserve exact face, head, body proportions, materials, colors, wardrobe, paint wear and distinctive marks",
          "no peer figures, no scale chart, no ruler, no grid, no diagram, no typography, no labels, no captions, no watermark"
        ].compact.join(". ")

        legacy_technical_reference = character["visual_prompt"].to_s.match?(TECHNICAL_REFERENCE_PATTERN)
        if legacy_technical_reference && character["image_url"].to_s.start_with?("http://", "https://")
          calibration_url = character["image_url"]
          character["scale_calibration_image_url"] ||= calibration_url
          character["qa_reference_images"] = (Array(character["qa_reference_images"]) + [calibration_url]).uniq
          character["reference_images"] = Array(character["reference_images"]).reject { |url| url == calibration_url }
          character["image_url"] = nil
        end

        before = [character["scale_reference"], character["visual_prompt"], character["scale_calibration_prompt"], character["forbidden_mutations"]].to_json
        character["scale_reference"] = rule
        character["source_identity_prompt"] = source_identity
        character["visual_prompt"] = narrative_instruction
        character["scale_calibration_prompt"] = reference_instruction
        character["physical_constraints"] = (Array(character["physical_constraints"]) +
          (mounted_figure ? [
            "The figure remains mechanically attached to its control rod until the screenplay explicitly depicts removal",
            "While attached it may rotate with or around the rod, translate only along the rod axis, strain, twist and show expressive source-defined agency; it may not walk freely across the playing surface or detach without a visible cause"
          ] : [])).uniq
        character["agency_mode"] = infer_agency_mode(source_identity, character)
        if mounted_figure
          character["allowed_attached_motion"] = [
            "rotation with or around the support rod",
            "translation along the rod axis",
            "expressive deformation or articulation that does not break the declared attachment"
          ]
        end
        character["forbidden_mutations"] = (Array(character["forbidden_mutations"]) +
          ["human-sized body", "giant or mascot scale", "larger than same-class peer figures"]).uniq
        character["scale_class"] = "miniature_peer"
        raw.replace(character.to_h) if raw.respond_to?(:replace)
        after = [character["scale_reference"], character["visual_prompt"], character["scale_calibration_prompt"], character["forbidden_mutations"]].to_json
        changed_ids << (character["id"].presence || "char_#{index + 1}") if before != after
      end

      rules = Array(assets["world_rules"])
      if changed_ids.any?
        rules << "same-class miniature figures preserve equal physical height on the same depth plane"
        rules << "cinematic framing never changes canonical physical scale"
      end
      assets["world_rules"] = rules.uniq
      original_assets.replace(assets.to_h) if original_assets.respond_to?(:replace) && !original_assets.equal?(assets)
      { "assets" => assets, "changed_asset_ids" => changed_ids.uniq }
    end

    private

    # Between July 18 and July 19, 2026 the overly broad technical-pattern
    # matcher classified clean narrative miniature references as calibration
    # plates. Repeated regenerations therefore accumulated valid portraits in
    # `qa_reference_images` while leaving `image_url` empty. Recover only the
    # unmistakable legacy shape: a clean narrative prompt, a known calibration
    # image and at least one additional remote QA image.
    def recover_misclassified_narrative_reference!(character)
      return unless character["visual_prompt"].to_s.match?(/\ACANONICAL NARRATIVE CHARACTER REFERENCE\s*[—-]\s*GENERATION SAFE/i)
      return if character["image_url"].present? || Array(character["reference_images"]).any? { |url| remote_url?(url) }

      calibration_url = character["scale_calibration_image_url"].to_s
      return unless remote_url?(calibration_url)

      qa_references = Array(character["qa_reference_images"]).map(&:to_s).select { |url| remote_url?(url) }.uniq
      recovered_url = qa_references.reverse.find { |url| url != calibration_url }
      return unless recovered_url

      character["image_url"] = recovered_url
      character["reference_images"] = [recovered_url]
      character["qa_reference_images"] = qa_references.reject { |url| url == recovered_url }
    end

    def remote_url?(value)
      value.to_s.start_with?("http://", "https://")
    end

    def infer_agency_mode(source_identity, character)
      text = [source_identity, character["personality_traits"], character["unique_behavior"]].join(" ")
      if text.match?(/alive|sentient|conscious|magical|fantast|chooses?|decides?|speaks?|talks?|hero|protagonist|cobra vida|con vida|sintiente|m[aá]gic|fant[aá]st|habla|decide/i)
        "fantastical_agency"
      else
        "mechanically_constrained"
      end
    end
  end
end
