# frozen_string_literal: true

require "digest"
require "json"
require "active_support/security_utils"

# Deterministic, zero-token production forecast. It combines an explainable
# stage model with observed local productions. Historical projects from the
# legacy pipeline are retained as lower-bound evidence, while current projects
# with visual QA receive substantially more calibration weight.
class ProductionTokenPredictor
  VERSION = "1.0"
  VISUAL_QA_BATCH_SIZE = 3
  VIDEO_QA_BATCH_SIZE = 4
  COMPLEXITY_PATTERNS = {
    "miniature_or_scale" => /miniature|figurine|foosball|futbol[ií]n|scale model|tamañ|escala|gigante|tiny|giant/i,
    "physical_interaction" => /impact|collision|kick|ball|gravity|break|fractur|water|fire|fight|choque|golpe|bal[oó]n|rompe/i,
    "identity_variants" => /child|older|younger|flashback|transform|replacement|restor|niñ|ancian|joven|reemplaz|transform|restaur/i,
    "crowd_or_multiple_subjects" => /crowd|army|team|group|multitude|multitud|equipo|ej[eé]rcito|varios personajes/i,
    "dense_cinematography" => /macro lens|slow motion|rack focus|shallow depth|crane|dolly|handheld|lente macro|c[aá]mara lenta/i
  }.freeze

  class << self
    def estimate(input:, history_scope: nil)
      facts = normalize_input(input)
      history = historical_samples(history_scope)
      risk = complexity_risk(facts)
      breakdown = analytic_breakdown(facts, risk)
      analytic_total = breakdown.values.sum
      historical_total = historical_projection(facts, history)
      blend_weight = history.empty? ? 0.0 : [0.12 + history.size * 0.05, 0.35].min
      expected = if historical_total
                   (analytic_total * (1.0 - blend_weight) + historical_total * blend_weight).round
                 else
                   analytic_total.round
                 end
      calibrated_breakdown = breakdown.transform_values { |value| value * expected.to_f / [analytic_total, 1].max }
      lower = round_up(expected * (0.78 - risk * 0.05), 500)
      upper_multiplier = 1.18 + risk * 0.28 + (history.size < 3 ? 0.12 : 0.0)
      upper = round_up(expected * upper_multiplier, 500)
      recommended = round_up(upper, 1_000)
      budget = facts["token_budget"]
      overrun = recommended > budget
      confidence = confidence_label(history)
      expected_credits = facts["dry_run"] ? 0 : expected_image_credits(facts, risk)

      {
        "version" => VERSION,
        "expected_tokens" => round_up(expected, 100),
        "likely_min_tokens" => lower,
        "likely_max_tokens" => upper,
        "recommended_budget" => recommended,
        "configured_budget" => budget,
        "potential_overrun_tokens" => [recommended - budget, 0].max,
        "overrun_required" => overrun,
        "confidence" => confidence,
        "historical_samples" => history.size,
        "current_pipeline_samples" => history.count { |sample| sample["current_pipeline"] },
        "estimated_scenes" => facts["estimated_scenes"],
        "estimated_shots" => facts["estimated_shots"],
        "estimated_image_credits" => expected_credits,
        "complexity_score" => (risk * 100).round,
        "risk_factors" => risk_factors(facts),
        "breakdown" => calibrated_breakdown.transform_values { |value| round_up(value, 100) },
        "approval_digest" => approval_digest(facts),
        "method" => "stage model + version-weighted local production history"
      }
    end

    def approval_digest(input)
      facts = input.is_a?(Hash) && input.key?("estimated_shots") ? input : normalize_input(input)
      payload = facts.slice(
        "prompt", "brain_dump", "duration", "resolution", "token_budget", "dry_run",
        "pipeline_mode", "adaptation_mode", "genre", "camera_style", "color_grade",
        "music_style", "voice_style", "max_scenes"
      )
      Digest::SHA256.hexdigest(JSON.generate([VERSION, payload]))
    end

    def input_from_project(project)
      direction = project.direction.to_h
      {
        prompt: project.prompt,
        brain_dump: direction["brain_dump"],
        duration: project.duration,
        resolution: project.resolution,
        token_budget: project.token_budget,
        dry_run: project.dry_run?,
        pipeline_mode: direction["pipeline_mode"],
        adaptation_mode: direction["adaptation_mode"],
        genre: direction["genre"],
        camera_style: direction["camera_style"],
        color_grade: direction["color_grade"],
        music_style: direction["music_style"],
        voice_style: direction["voice_style"],
        max_scenes: direction["max_scenes"]
      }
    end

    def authorization_valid_for_project?(project)
      direction = project.direction.to_h
      return false unless ActiveRecord::Type::Boolean.new.cast(direction["production_token_overrun_authorized"])
      return false if direction["production_token_overrun_consumed_at"].present?

      supplied = direction["production_token_overrun_digest"].to_s
      expected = approval_digest(input_from_project(project))
      supplied.length == expected.length && ActiveSupport::SecurityUtils.secure_compare(supplied, expected)
    end

    def approval_valid?(forecast:, supplied_digest:, approved:)
      return true unless forecast["overrun_required"]
      return false unless ActiveRecord::Type::Boolean.new.cast(approved)

      expected = forecast["approval_digest"].to_s
      supplied = supplied_digest.to_s
      supplied.length == expected.length && ActiveSupport::SecurityUtils.secure_compare(supplied, expected)
    end

    private

    def normalize_input(input)
      raw = input.respond_to?(:to_h) ? input.to_h.with_indifferent_access : {}.with_indifferent_access
      project = raw["project"].respond_to?(:to_h) ? raw["project"].to_h.with_indifferent_access : {}.with_indifferent_access
      value = ->(key) { project[key].presence || raw[key] }
      # JSON requests use LF while native HTML form submissions encode textarea
      # newlines as CRLF. Canonicalize both before calculating the approval
      # digest so an unchanged screenplay cannot invalidate its own approval.
      prompt = canonical_text(value.call("prompt"))
      brain_dump = canonical_text(value.call("brain_dump"))
      raw_duration = value.call("duration").to_i
      duration = raw_duration.positive? ? raw_duration.clamp(10, 300) : 75
      max_scenes = value.call("max_scenes").to_i
      max_scenes = nil unless max_scenes.positive?
      estimated_scenes, estimated_shots = estimate_structure(prompt, duration, max_scenes)

      {
        "prompt" => prompt,
        "brain_dump" => brain_dump,
        "prompt_chars" => prompt.length + brain_dump.length,
        "input_tokens" => ((prompt.length + brain_dump.length) / 4.0).ceil,
        "duration" => duration,
        "resolution" => value.call("resolution").presence || "720P",
        "token_budget" => value.call("token_budget").to_i.positive? ? [value.call("token_budget").to_i, 5_000].max : 18_000,
        "dry_run" => ActiveRecord::Type::Boolean.new.cast(value.call("dry_run")),
        "pipeline_mode" => value.call("pipeline_mode").presence || "agentic",
        "adaptation_mode" => value.call("adaptation_mode").presence || "faithful",
        "genre" => value.call("genre").to_s,
        "camera_style" => value.call("camera_style").to_s,
        "color_grade" => value.call("color_grade").to_s,
        "music_style" => value.call("music_style").to_s,
        "voice_style" => value.call("voice_style").to_s,
        "max_scenes" => max_scenes,
        "estimated_scenes" => estimated_scenes,
        "estimated_shots" => estimated_shots,
        "structured" => structured_prompt?(prompt),
        "matched_complexities" => COMPLEXITY_PATTERNS.keys.select { |key| prompt.match?(COMPLEXITY_PATTERNS[key]) }
      }
    end

    def estimate_structure(prompt, duration, max_scenes)
      lines = prompt.lines.map(&:strip)
      explicit_scenes = lines.count { |line| line.match?(/\A(?:##\s+(?!#)|scene\s+\d+|escena\s+\d+|int\.?\s|ext\.?\s)/i) }
      explicit_shots = lines.count { |line| line.match?(/\A(?:###\s+(?!#)|shot\s*\d*|toma\s*\d*|plano\s*\d*)/i) }
      scenes = explicit_scenes.positive? ? explicit_scenes : [(duration / 12.0).ceil, 2].max
      scenes = [scenes, max_scenes].min if max_scenes
      cadence_shots = (duration / (prompt.length > 1_200 ? 4.4 : 5.2)).ceil
      shots = [explicit_shots, scenes, cadence_shots, 3].max
      [scenes.clamp(1, 20), shots.clamp(scenes, 80)]
    end

    def structured_prompt?(prompt)
      prompt.length >= 800 || prompt.match?(/\A(?:##|scene\s+\d+|escena\s+\d+|int\.|ext\.)/im)
    end

    def complexity_risk(facts)
      score = 0.18
      score += [facts["prompt_chars"] / 18_000.0, 0.22].min
      score += [facts["estimated_shots"] / 80.0, 0.18].min
      score += facts["matched_complexities"].size * 0.055
      score += 0.07 if facts["resolution"] == "1080P"
      score += 0.06 if facts["adaptation_mode"] == "transmuted"
      score += 0.04 if %w[handheld_shaky dutch_angles_extreme].include?(facts["camera_style"])
      score.clamp(0.18, 0.92)
    end

    def analytic_breakdown(facts, risk)
      input_tokens = facts["input_tokens"]
      scenes = facts["estimated_scenes"]
      shots = facts["estimated_shots"]
      entity_estimate = [2 + (facts["prompt_chars"] / 2_500.0).ceil + facts["matched_complexities"].size / 2, 10].min
      narrative = 2_800 + input_tokens * 0.62 + scenes * 170
      assets = 3_000 + entity_estimate * 720 + input_tokens * 0.32
      storyboard = 1_100 + shots * 125

      if facts["dry_run"]
        visual_qa = 0
        repairs = 0
        video_qa = 0
      else
        visual_batches = (shots.to_f / VISUAL_QA_BATCH_SIZE).ceil
        video_batches = (shots.to_f / VIDEO_QA_BATCH_SIZE).ceil
        visual_qa = visual_batches * 3_800
        repairs = (visual_qa * (0.22 + risk * 0.42)) + shots * 120
        video_qa = video_batches * 3_100
      end

      {
        "narrative_and_edit_plan" => narrative,
        "canonical_asset_profiling" => assets,
        "storyboard_prompt_compilation" => storyboard,
        "storyboard_visual_qa" => visual_qa,
        "repair_and_recheck_reserve" => repairs,
        "final_video_qa" => video_qa
      }
    end

    def historical_samples(scope)
      return [] unless scope

      records = scope.respond_to?(:where) ? scope.where("tokens_used > 0").order(id: :desc).limit(30) : Array(scope)
      records.filter_map do |project|
        manifest = project.manifest.to_h
        shots = Array(manifest.dig("screenplay", "scenes")).sum { |scene| Array(scene["shots"]).size }
        next if project.tokens_used.to_i <= 0

        {
          "tokens_used" => project.tokens_used.to_i,
          "duration" => project.duration.to_i,
          "prompt_chars" => project.prompt.to_s.length,
          "shots" => shots,
          "resolution" => project.resolution.to_s,
          "current_pipeline" => manifest["production_bible"].present? && manifest.dig("consistency_report", "visual_metrics").present?,
          "visual_metrics" => manifest.dig("consistency_report", "visual_metrics").to_h,
          "visual_tokens" => Array(manifest.dig("budget_ledger", "calls")).select { |call| (call["stage"] || call[:stage]).to_s == "visual_consistency" }.sum { |call| (call["tokens"] || call[:tokens]).to_i }
        }
      end
    rescue StandardError
      []
    end

    def historical_projection(facts, history)
      return if history.empty?

      projections = history.map do |sample|
        sample_shots = [sample["shots"], 1].max
        scale = (facts["estimated_shots"].to_f / sample_shots)**0.62
        scale *= (facts["prompt_chars"].to_f / [sample["prompt_chars"], 100].max).clamp(0.55, 1.8)**0.18
        observed = sample["tokens_used"] * scale

        if sample["current_pipeline"] && sample["visual_metrics"]["status"] != "measured" && !facts["dry_run"]
          measured = Array(sample["visual_metrics"]["partial_shots"]).size
          remaining_batches = [(facts["estimated_shots"] - measured).to_f / VISUAL_QA_BATCH_SIZE, 0].max.ceil
          per_batch = sample["visual_tokens"].positive? ? sample["visual_tokens"] : 3_800
          observed += remaining_batches * per_batch
        elsif !sample["current_pipeline"] && !facts["dry_run"]
          # Legacy runs did not include the mandatory storyboard and video QA
          # added after the consistency failures; treat their usage as a floor.
          observed += (facts["estimated_shots"].to_f / VISUAL_QA_BATCH_SIZE).ceil * 2_300
        end
        weight = sample["current_pipeline"] ? 1.0 : 0.28
        [observed, weight]
      end
      total_weight = projections.sum(&:last)
      projections.sum { |value, weight| value * weight } / total_weight
    end

    def expected_image_credits(facts, risk)
      shots = facts["estimated_shots"]
      canonical_assets = [3 + (facts["prompt_chars"] / 4_000.0).ceil, 9].min
      continuity_plates = facts["estimated_scenes"]
      repairs = (shots * (0.18 + risk * 0.35)).ceil
      shots + canonical_assets + continuity_plates + repairs
    end

    def risk_factors(facts)
      labels = facts["matched_complexities"].map { |key| key.humanize }
      labels << "Long structured screenplay" if facts["structured"] && facts["prompt_chars"] > 4_000
      labels << "1080p visual review" if facts["resolution"] == "1080P"
      labels << "Creative adaptation" if facts["adaptation_mode"] == "transmuted"
      labels << "#{facts['estimated_shots']} estimated shots" if facts["estimated_shots"] >= 12
      labels.uniq
    end

    def confidence_label(history)
      current = history.count { |sample| sample["current_pipeline"] }
      return "high" if current >= 10
      return "moderate" if history.size >= 3 || current >= 2
      return "low" if history.empty?

      "early"
    end

    def round_up(value, step)
      (value.to_f / step).ceil * step
    end

    def canonical_text(value)
      value.to_s.gsub(/\r\n?/, "\n").strip
    end
  end
end
