# frozen_string_literal: true

# Uses Qwen visual understanding to compare canonical references with approved
# storyboard keyframes before expensive video synthesis. It is intentionally a
# pre-render gate; final-video temporal metrics remain a separate concern.
require "stable_media"

class VisualConsistencyEvaluator
  MAX_IMAGES = 24
  SHOTS_PER_BATCH = 3
  PASS_THRESHOLD = 85
  DIMENSION_THRESHOLDS = {
    "identity_score" => 85,
    "prop_score" => 85,
    "scale_score" => 90,
    "physics_plausibility_score" => 85
  }.freeze
  CRITICAL_ISSUE_PATTERN = /significantly larger|oversized|giant scale|wrong scale|not mounted|rather than mounted|not attached|identity mismatch|different face|different (?:color|material)|missing required|violat\w* (?:the )?(?:attachment|scale|identity|physical)|unrequested (?:visible )?text|calibration (?:sheet|grid)|visible (?:labels?|ruler|typography)|technical diagram|interface overlay/i

  class << self
    def evaluate(screenplay:, production_bible:, shot_ids: nil, ledger: nil, config: QwenRouter::Config.default,
                 cancellation_check: nil)
      cancellation_check&.call
      shots = Array(screenplay["scenes"]).flat_map { |scene| Array(scene["shots"]) }
      shots = shots.select { |shot| preferred_reference(shot["stable_image_url"], shot["image_url"]).present? }
      wanted = Array(shot_ids).map(&:to_s)
      shots.select! { |shot| wanted.include?(shot["id"].to_s) } if wanted.any?
      return unavailable("no remote storyboard keyframes") if shots.empty?

      entity_index = ProductionBible.entity_index(production_bible)
      batch_reports = shots.each_slice(SHOTS_PER_BATCH).map do |batch|
        cancellation_check&.call
        evaluate_batch(batch, entity_index, ledger, config)
      end
      incomplete = batch_reports.reject { |report| report["status"] == "measured" }
      measured_rows = batch_reports.flat_map { |report| Array(report["shots"]) }
      if incomplete.any?
        return unavailable(incomplete.map { |report| report["reason"] }.compact.join("; ")).merge(
          "partial_shots" => measured_rows,
          "batches" => batch_reports.size
        )
      end

      {
        "status" => "measured",
        "models" => batch_reports.map { |report| report["model"] }.compact.uniq,
        "pass_threshold" => PASS_THRESHOLD,
        "dimension_thresholds" => DIMENSION_THRESHOLDS,
        "shots_evaluated" => measured_rows.size,
        "shots" => measured_rows,
        "failed_shot_ids" => measured_rows.reject { |row| row["pass"] }.map { |row| row["shot_id"] },
        "average_score" => measured_rows.any? ? (measured_rows.sum { |row| row["overall_score"] }.to_f / measured_rows.size).round(1) : nil,
        "summary" => batch_reports.map { |report| report["summary"] }.compact.join(" "),
        "batches" => batch_reports.size
      }
    rescue ActiveRecord::RecordNotFound
      raise
    rescue StandardError => e
      unavailable(e.message)
    end

    private

    def evaluate_batch(selected_shots, entity_index, ledger, config)
      content = [{ type: "text", text: evaluation_manifest(selected_shots, entity_index) }]
      referenced_ids = selected_shots.flat_map { |shot| Array(shot.dig("continuity", "required_entity_ids")) }.uniq
      referenced_ids.each do |entity_id|
        entity = entity_index[entity_id]
        url = ProductionBible.narrative_reference_images(entity || {}).find { |candidate| remote_url?(candidate) }
        next unless url

        content << { type: "text", text: "CANONICAL REFERENCE #{entity_id}" }
        content << { type: "image_url", image_url: { url: url }, max_pixels: 256 * 256 }
      end
      referenced_ids.each do |entity_id|
        entity = entity_index[entity_id]
        qa_references = Array(entity&.dig("qa_reference_images")) +
          Array(entity&.dig("stable_qa_reference_images")) +
          [entity&.dig("scale_calibration_image_url"), entity&.dig("stable_scale_calibration_image_url")]
        qa_references.compact.uniq.select { |candidate| remote_url?(candidate) }.first(1).each do |url|
          content << { type: "text", text: "QA-ONLY SCALE EVIDENCE #{entity_id} — NEVER EXPECT THIS PLATE'S TEXT OR LAYOUT IN THE STORYBOARD" }
          content << { type: "image_url", image_url: { url: url }, max_pixels: 256 * 256 }
        end
      end
      selected_shots.filter_map do |shot|
        stable = shot.dig("continuity", "stable_continuity_plate_url")
        StableMedia.local_available?(stable) ? stable : shot.dig("continuity", "continuity_plate_url")
      end
        .select { |url| remote_url?(url) }.uniq.each_with_index do |url, index|
          content << { type: "text", text: "APPROVED MASTER CONTINUITY PLATE #{index + 1} — SCALE AND SPATIAL REFERENCE" }
          content << { type: "image_url", image_url: { url: url }, max_pixels: 384 * 384 }
        end
      selected_shots.each do |shot|
        keyframe_url = preferred_reference(shot["stable_image_url"], shot["image_url"])
        content << { type: "text", text: "STORYBOARD KEYFRAME #{shot['id']}" }
        content << {
          type: "image_url",
          image_url: { url: keyframe_url },
          max_pixels: 256 * 256
        }
      end

      parsed, result = QwenRouter.call_vision_json(
        system: system_prompt,
        content: content,
        stage: :visual_consistency,
        max_tokens: [selected_shots.size * 220, 600].max,
        ledger: ledger,
        config: config
      )
      normalize(parsed, result, selected_shots)
    rescue StandardError => e
      unavailable(e.message)
    end

    def system_prompt
      <<~PROMPT
        You are a strict film continuity supervisor. Compare every STORYBOARD
        KEYFRAME against the labeled CANONICAL REFERENCES and the JSON contract.
        Evaluate only visible evidence. Never reward cinematic beauty when an
        identity, prop, color, material, scale or physical constraint changed.
        Relative scale is geometric, not dramatic: compare subjects that share
        a depth plane. A miniature enlarged beyond same-class peer figures is a
        scale failure even when a low angle intentionally makes it feel heroic.
        HARD GATES: overall must be >= #{PASS_THRESHOLD}; identity and prop must
        each be >= 85; physics must be >= 85; scale must be >= 90. No average
        can compensate for one failed dimension. If visible evidence says a
        subject is significantly larger, not mounted, identity-mismatched or
        physically contradictory, pass MUST be false. Unrequested visible text,
        calibration rulers/grids, technical labels, diagrams, watermarks or UI
        copied from an internal reference are also hard failures. Text is only
        allowed when the shot contract explicitly requests diegetic text. Return exactly one row
        for every requested shot_id and never omit a row. Return ONLY JSON:
        {
          "shots": [{
            "shot_id": string,
            "identity_score": integer,
            "prop_score": integer,
            "scale_score": integer,
            "physics_plausibility_score": integer,
            "overall_score": integer,
            "pass": boolean,
            "issues": [string]
          }],
          "summary": string
        }
      PROMPT
    end

    def evaluation_manifest(shots, entity_index)
      referenced_ids = shots.flat_map { |shot| Array(shot.dig("continuity", "required_entity_ids")) }.uniq
      entities = referenced_ids.filter_map do |id|
        entity = entity_index[id]
        next unless entity

        {
          id: id,
          type: entity["type"],
          descriptor: compact(entity["canonical_descriptor"], 160),
          immutable_traits: Array(entity["immutable_traits"]).first(5).map { |value| compact(value, 80) },
          scale_reference: compact(entity["scale_reference"], 220),
          physical_constraints: Array(entity["physical_constraints"]).first(4).map { |value| compact(value, 100) }
        }
      end
      shot_contracts = shots.map do |shot|
        {
          shot_id: shot["id"],
          required_entity_ids: Array(shot.dig("continuity", "required_entity_ids")),
          action: compact(shot["visual_prompt"], 180)
        }
      end
      "EVALUATION CONTRACT: #{JSON.generate({ entities: entities, shots: shot_contracts })}"
    end

    def normalize(parsed, result, selected_shots)
      payload = normalize_payload(parsed)
      raw_shots = Array(payload["shots"])
      expected_ids = selected_shots.map { |shot| shot["id"].to_s }
      results = raw_shots.filter_map do |item|
        next unless item.respond_to?(:to_h)
        row = item.to_h.stringify_keys
        next unless expected_ids.include?(row["shot_id"].to_s)

        overall = row["overall_score"].to_i.clamp(0, 100)
        row["overall_score"] = overall
        row["issues"] = Array(row["issues"]).map(&:to_s)
        DIMENSION_THRESHOLDS.each_key { |key| row[key] = row[key].to_i.clamp(0, 100) }
        hard_failures = DIMENSION_THRESHOLDS.filter_map do |key, threshold|
          "#{key}=#{row[key]} below #{threshold}" if row[key] < threshold
        end
        hard_failures << "critical visible inconsistency" if row["issues"].any? { |text| text.match?(CRITICAL_ISSUE_PATTERN) }
        row["hard_failures"] = hard_failures.uniq
        row["pass"] = ActiveRecord::Type::Boolean.new.cast(row["pass"]) &&
          overall >= PASS_THRESHOLD && row["hard_failures"].empty?
        row
      end
      missing_ids = expected_ids - results.map { |row| row["shot_id"].to_s }
      results.concat(missing_ids.map { |id| missing_result(id) })

      {
        "status" => missing_ids.empty? ? "measured" : "incomplete",
        "reason" => missing_ids.any? ? "vision evaluator omitted: #{missing_ids.join(', ')}" : nil,
        "model" => result.raw["model"],
        "pass_threshold" => PASS_THRESHOLD,
        "dimension_thresholds" => DIMENSION_THRESHOLDS,
        "shots_evaluated" => results.size,
        "shots" => results,
        "failed_shot_ids" => results.reject { |row| row["pass"] }.map { |row| row["shot_id"] },
        "average_score" => results.any? ? (results.sum { |row| row["overall_score"] }.to_f / results.size).round(1) : nil,
        "summary" => payload["summary"]
      }
    end

    # Vision models occasionally honor the row schema but return the rows as
    # the JSON root (or wrap them in `result`/`data`). Treat those equivalent
    # shapes as valid instead of turning a completed audit into `not_measured`.
    def normalize_payload(parsed)
      case parsed
      when Array
        { "shots" => parsed }
      when Hash
        payload = parsed.stringify_keys
        nested = payload["result"] || payload["data"] || payload["evaluation"]
        nested_payload = normalize_payload(nested) if nested.is_a?(Hash) || nested.is_a?(Array)
        payload["shots"] ||= nested_payload&.dig("shots")
        payload["summary"] ||= nested_payload&.dig("summary")
        payload
      else
        { "shots" => [] }
      end
    end

    def unavailable(reason)
      { "status" => "not_measured", "reason" => reason.to_s }
    end

    def missing_result(shot_id)
      {
        "shot_id" => shot_id,
        "overall_score" => 0,
        "pass" => false,
        "issues" => ["vision evaluator omitted this shot"],
        "hard_failures" => ["visual audit row missing"]
      }
    end

    def remote_url?(value)
      StableMedia.reference?(value)
    end

    def preferred_reference(stable, remote)
      return stable if StableMedia.local_available?(stable)
      return remote if StableMedia.reference?(remote)

      nil
    end

    def compact(value, limit)
      value.to_s.squish.first(limit)
    end
  end
end
