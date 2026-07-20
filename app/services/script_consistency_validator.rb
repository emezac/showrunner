# frozen_string_literal: true

require_relative "production_bible"

# Validates the generation meaning of a screenplay against the canonical
# production contract. Source prose remains available for review, while
# contradictory generation actions are either reconciled deterministically or
# blocked before visual credits are spent.
class ScriptConsistencyValidator
  VERSION = "1.0"

  ATTACHMENT_PATTERN = /\b(?:fixed|attached|mounted|embedded|fastened|anchored|sujeto|fijado|montado|anclado)\b/i
  LOCOMOTION_PATTERN = /\b(?:walk(?:s|ed|ing)?|run(?:s|ran|ning)?|step(?:s|ped|ping)?|advance(?:s|d|ing)?|moves?\s+(?:toward|towards|forward)|camina|corre|avanza|da\s+pasos?)\b/i
  RELEASE_PATTERN = /\b(?:detach(?:es|ed|ing)?|remove(?:s|d|ing)?|release(?:s|d|ing)?|breaks?\s+free|unfasten(?:s|ed|ing)?|desmonta|retira|libera|desprende)\b/i
  SCALE_MUTATION_PATTERN = /\b(?:grows?|shrinks?|becomes?\s+(?:giant|human[- ]sized|tiny)|changes?\s+(?:physical\s+)?size|crece|encoge|se\s+vuelve\s+gigante|cambia\s+de\s+tamañ[oa])\b/i
  IDENTITY_MUTATION_PATTERN = /\b(?:(?:he|she|they|character|subject|protagonist|hero|él|ella|personaje|sujeto|protagonista|héroe)\s+(?:transforms?\s+into|turns?\s+into|becomes?\s+(?:another|a different)|se\s+transforma\s+en|se\s+convierte\s+en)|changes?\s+(?:face|body|species|identity)|cambia\s+(?:de\s+)?(?:rostro|cuerpo|especie|identidad))\b/i
  CINEMATIC_SCALE_PATTERN = /\b(?:appear(?:s|ing)?|look(?:s|ing)?|seem(?:s|ing)?|hacer(?:lo|la)?\s+parecer|parece)\s+(?:much\s+)?(?:larger|bigger|giant|más\s+grande|gigante)\b/i

  class << self
    def reconcile!(screenplay:, production_bible:)
      original_screenplay = screenplay
      screenplay = screenplay.with_indifferent_access
      entity_index = ProductionBible.entity_index(production_bible)
      report_issues = []
      resolved_count = 0
      replacements = {}

      Array(screenplay["scenes"]).each do |scene|
        Array(scene["shots"]).each do |shot|
          original = shot["source_generation_action"].to_s.presence || generation_action(shot)
          shot["source_generation_action"] ||= original
          constraints = applicable_constraints(shot, production_bible, entity_index)
          entities = required_entities(shot, entity_index)
          shot_issues = []
          resolved = original.dup

          if attachment_conflict?(original, constraints)
            resolved = mounted_agency_action(original, entities)
            shot_issues << issue(
              "warning", shot["id"], "attached_subject_locomotion_reconciled",
              "Independent locomotion contradicted a canonical attachment; generation was converted to visible attachment-compatible character motion.",
              resolution: "canonical_override"
            )
          end

          if scale_mutation?(original, entities, production_bible)
            shot_issues << issue(
              "critical", shot["id"], "undeclared_scale_transformation",
              "The script changes canonical physical scale without declaring and profiling a separate canonical variant.",
              resolution: "requires_canonical_variant"
            )
          elsif cinematic_scale_conflict?(original, entities, production_bible)
            resolved = preserve_scale_action(resolved)
            shot_issues << issue(
              "warning", shot["id"], "cinematic_scale_language_reconciled",
              "Dramatic prominence was retained as framing only; canonical physical scale remains unchanged.",
              resolution: "framing_only"
            )
          end

          if identity_mutation?(original, entities)
            shot_issues << issue(
              "critical", shot["id"], "undeclared_identity_transformation",
              "The script changes canonical identity/body without a separately profiled canonical variant.",
              resolution: "requires_canonical_variant"
            )
          end

          if resolved.present? && resolved != original
            apply_resolution!(shot, original, resolved)
            replacements[original] = resolved
          end
          resolved_count += 1 if resolved != original
          shot["script_consistency"] = {
            "status" => shot_issues.any? { |item| item["severity"] == "critical" } ? "blocked" : "consistent",
            "source_action" => original,
            "resolved_action" => resolved,
            "issues" => shot_issues
          }
          report_issues.concat(shot_issues)
        end
      end
      rewrite_consistency_states_in_screenplay!(screenplay, replacements) if replacements.any?

      critical_count = report_issues.count { |item| item["severity"] == "critical" }
      report = {
        "version" => VERSION,
        "status" => critical_count.zero? ? "ready" : "blocked",
        "ready" => critical_count.zero?,
        "critical_count" => critical_count,
        "resolved_count" => resolved_count,
        "issues" => report_issues,
        "policy" => production_bible&.dig("consistency_policy")
      }
      screenplay["script_consistency_report"] = report
      if original_screenplay.respond_to?(:replace) && !original_screenplay.equal?(screenplay)
        original_screenplay.replace(screenplay.to_h)
      end
      report
    end

    private

    def generation_action(shot)
      shot["resolved_generation_action"].to_s.presence ||
        shot["generation_action"].to_s.presence ||
        shot.dig("prompt_components", "action").to_s.presence ||
        shot["source_visual_prompt"].to_s.presence ||
        shot["visual_prompt"].to_s
    end

    def applicable_constraints(shot, bible, entity_index)
      ids = Array(shot.dig("continuity", "required_entity_ids"))
      entity_rules = ids.flat_map { |id| Array(entity_index.dig(id.to_s, "physical_constraints")) }
      (Array(shot.dig("continuity", "physical_constraints")) + entity_rules + Array(bible&.dig("global_invariants")))
        .map(&:to_s).uniq.join("; ")
    end

    def required_entities(shot, entity_index)
      Array(shot.dig("continuity", "required_entity_ids")).filter_map { |id| entity_index[id.to_s] }
    end

    def attachment_conflict?(action, constraints)
      return false if action.match?(/remains mechanically attached.*(?:rod|support)|no independent (?:walking|locomotion)/i)

      constraints.match?(ATTACHMENT_PATTERN) && action.match?(LOCOMOTION_PATTERN) && !action.match?(RELEASE_PATTERN)
    end

    def scale_mutation?(action, entities, bible)
      return false unless action.match?(SCALE_MUTATION_PATTERN)

      entities.any? { |entity| entity["scale_reference"].present? } || Array(bible&.dig("scale_anchors")).any?
    end

    def cinematic_scale_conflict?(action, entities, bible)
      action.match?(CINEMATIC_SCALE_PATTERN) &&
        (entities.any? { |entity| entity["scale_reference"].present? } || Array(bible&.dig("scale_anchors")).any?)
    end

    def identity_mutation?(action, entities)
      action.match?(IDENTITY_MUTATION_PATTERN) && entities.any? do |entity|
        Array(entity["immutable_traits"]).any? || entity["canonical_descriptor"].present?
      end
    end

    def mounted_agency_action(original, entities)
      entity = entities.find { |candidate| !%w[prop location].include?(candidate["type"]) }
      subject = entity&.dig("name") || "The canonical subject"
      allowed = Array(entity&.dig("allowed_attached_motion")).presence || [
        "rotation around the declared attachment",
        "translation only along the support axis",
        "expressive strain without breaking the attachment"
      ]
      intent = original.match?(/toward|towards|forward|hacia|avanza/i) ?
        "visibly attempts the intended forward approach" : "visibly performs the intended action"
      "#{subject} remains mechanically attached at the canonical anchor and #{intent} through #{allowed.join(', ')}. Preserve clear character agency, effort and reaction while the support and camera may move to reinforce the action. No independent walking across the surface, free detachment or change of physical scale occurs."
    end

    def preserve_scale_action(action)
      cleaned = action.gsub(CINEMATIC_SCALE_PATTERN, "appear more visually prominent")
      "#{cleaned} Canonical physical size and relative scale remain unchanged; show a same-class or environmental scale anchor in frame."
    end

    def apply_resolution!(shot, original, resolved)
      shot["source_story_event"] ||= shot["story_event"].to_s.presence || original
      shot["resolved_generation_action"] = resolved
      shot["generation_action"] = resolved
      shot["story_event"] = resolved
      shot["exit_state"] = shot["exit_state"].to_h.merge("event" => resolved, "status" => "canonical-consistent result")
    end

    def rewrite_consistency_states_in_screenplay!(screenplay, replacements)
      Array(screenplay["scenes"]).each do |scene|
        rewrite_state_value!(scene["continuity_in"], replacements)
        rewrite_state_value!(scene["continuity_out"], replacements)
        Array(scene["shots"]).each do |shot|
          rewrite_state_value!(shot["entry_state"], replacements)
          rewrite_state_value!(shot["exit_state"], replacements)
          rewrite_state_value!(shot["continuity"], replacements)
        end
      end
    end

    def rewrite_state_value!(value, replacements)
      case value
      when Hash
        value.each_value { |item| rewrite_state_value!(item, replacements) }
      when Array
        value.each { |item| rewrite_state_value!(item, replacements) }
      when String
        replacements.each { |source, resolved| value.replace(value.gsub(source, resolved)) if value.include?(source) }
      end
    end

    def issue(severity, shot_id, code, message, resolution:)
      {
        "severity" => severity,
        "shot_id" => shot_id,
        "code" => code,
        "message" => message,
        "resolution" => resolution
      }
    end
  end
end
