# frozen_string_literal: true

require "base64"
require "fileutils"
require "open3"
require "tmpdir"

# Samples generated clips and asks Qwen Vision to verify actual pixels and
# temporal behavior before Editor assembles the final cut.
class VideoConsistencyEvaluator
  VERSION = "2.0"
  SHOTS_PER_BATCH = 4
  FRAMES_PER_SHOT = 5
  MIN_FRAMES_PER_SHOT = 4
  PASS_THRESHOLD = 85
  DIMENSION_THRESHOLDS = {
    "identity_score" => 85,
    "prop_score" => 85,
    "scale_score" => 90,
    "temporal_stability_score" => 85,
    "physics_score" => 85
  }.freeze
  ABSOLUTE_CRITICAL_ISSUE_PATTERN = /identity drift|different face|significantly larger|oversized|wrong scale|not mounted|not attached|teleport|missing required|violat\w* (?:attachment|scale|identity|physics)|unrequested (?:visible )?text|calibration (?:sheet|grid)|visible (?:labels?|ruler|typography)|technical diagram|interface overlay/i
  MORPH_ISSUE_PATTERN = /morph/i
  MINOR_QUALIFIER_PATTERN = /\b(?:minor|mild|slight|slightly|subtle|brief|momentary)\b/i

  class << self
    def evaluate(screenplay:, shot_paths:, production_bible:, ledger: nil, config: QwenRouter::Config.default)
      shots = Array(screenplay["scenes"]).flat_map { |scene| Array(scene["shots"]) }
      available = shots.filter_map do |shot|
        path = shot_paths[shot["id"]]
        [shot, path] if path.present? && File.file?(path)
      end
      return unavailable("no generated clips") if available.empty?

      batch_reports = available.each_slice(SHOTS_PER_BATCH).flat_map do |batch|
        evaluate_with_isolation(batch, production_bible, ledger, config)
      end

      rows = batch_reports.flat_map do |ids, report|
        if report["status"] == "measured"
          Array(report["shots"])
        else
          ids.map do |shot_id|
            {
              "shot_id" => shot_id,
              "audit_status" => "unavailable",
              "overall_score" => nil,
              "pass" => nil,
              "issues" => ["video vision audit unavailable: #{report['reason']}"]
            }
          end
        end
      end
      unavailable_rows, measured_rows = rows.partition { |row| row["audit_status"] == "unavailable" }
      failed_rows = measured_rows.reject { |row| row["pass"] }
      status = unavailable_rows.any? ? "incomplete" : "measured"
      reasons = unavailable_rows.flat_map { |row| Array(row["issues"]) }.uniq

      {
        "evaluator_version" => VERSION,
        "status" => status,
        "reason" => (reasons.join("; ") if reasons.any?),
        "pass_threshold" => PASS_THRESHOLD,
        "shots_evaluated" => measured_rows.size,
        "shots_requested" => rows.size,
        "shots" => rows,
        "failed_shot_ids" => failed_rows.map { |row| row["shot_id"] },
        "audit_unavailable_shot_ids" => unavailable_rows.map { |row| row["shot_id"] },
        "average_score" => if measured_rows.any?
                             (measured_rows.sum { |row| row["overall_score"].to_i }.to_f / measured_rows.size).round(1)
                           end
      }.compact
    rescue StandardError => e
      unavailable(e.message)
    end

    private

    def evaluate_with_isolation(batch, production_bible, ledger, config)
      ids = batch.map { |shot, _path| shot["id"].to_s }
      report = evaluate_batch(batch, production_bible, ledger, config)
      return [[ids, report]] if report["status"] == "measured" || batch.one?

      # A malformed/too-short video in a batch must not turn every neighboring
      # shot into a visual failure. Retry each clip independently so the exact
      # unavailable shot is identified without regenerating any media.
      batch.map do |entry|
        shot_id = entry.first["id"].to_s
        [[shot_id], evaluate_batch([entry], production_bible, ledger, config)]
      end
    end

    def evaluate_batch(batch, production_bible, ledger, config)
      content = [{ type: "text", text: contract_for(batch, production_bible) }]
      Dir.mktmpdir("video_consistency_") do |dir|
        batch.each do |shot, path|
          frames = extract_frames(path, dir, shot["id"])
          if frames.size < MIN_FRAMES_PER_SHOT
            return unavailable(
              "shot #{shot['id']} produced #{frames.size} sampled frame(s); at least #{MIN_FRAMES_PER_SHOT} are required"
            )
          end

          content << { type: "text", text: "GENERATED VIDEO SHOT #{shot['id']}" }
          content << { type: "video", video: frames.map { |frame| data_url(frame) } }
        end

        parsed, = QwenRouter.call_vision_json(
          system: system_prompt,
          content: content,
          stage: :video_consistency,
          max_tokens: [batch.size * 200, 600].max,
          ledger: ledger,
          config: config
        )
        normalize(parsed, batch.map { |shot, _path| shot["id"].to_s })
      end
    rescue StandardError => e
      unavailable(e.message)
    end

    def unavailable_row(shot_id, reason)
      {
        "shot_id" => shot_id,
        "audit_status" => "unavailable",
        "overall_score" => nil,
        "pass" => nil,
        "issues" => [reason]
      }
    end

    def system_prompt
      <<~PROMPT
        You are a strict film continuity and physics supervisor. Each labeled
        video is a sequence of sampled frames from one generated shot. Compare
        visible identity, wardrobe, props, colors, materials and relative scale
        to the supplied canonical contract. Check temporal stability, contact,
        gravity, inertia, attachments and whether objects morph or teleport.
        Unrequested visible text, calibration rulers/grids, technical labels,
        diagrams, watermarks or interface overlays copied from a reference are
        hard failures unless the shot contract explicitly requests diegetic text.
        Do not reward beauty over continuity. Overall must be at least
        #{PASS_THRESHOLD}; identity, props, temporal stability and physics must
        each be at least 85, and scale at least 90. No average compensates for
        a failed dimension. Return exactly one row per shot. Return ONLY JSON:
        {"shots":[{"shot_id":string,"identity_score":integer,
        "prop_score":integer,"scale_score":integer,"temporal_stability_score":integer,
        "physics_score":integer,"overall_score":integer,"pass":boolean,
        "issues":[string]}]}
      PROMPT
    end

    def contract_for(batch, bible)
      index = ProductionBible.entity_index(bible)
      payload = batch.map do |shot, _path|
        ids = Array(shot.dig("continuity", "required_entity_ids"))
        {
          shot_id: shot["id"],
          entities: ids.filter_map do |id|
            entity = index[id]
            next unless entity
            entity.slice("id", "type", "name", "canonical_descriptor", "immutable_traits", "scale_reference", "physical_constraints")
          end,
          continuity: shot["continuity"].to_h.slice("initial_state", "final_state", "screen_direction"),
          action: shot["visual_prompt"]
        }
      end
      "CANONICAL VIDEO CONTRACT: #{JSON.generate(payload)}"
    end

    def extract_frames(path, dir, shot_id)
      prefix = File.join(dir, "#{shot_id.to_s.tr('.', '_')}_%02d.jpg")
      command = [
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-i", path,
        "-vf", "tpad=stop_mode=clone:stop_duration=2,fps=2,scale=256:-2",
        "-frames:v", FRAMES_PER_SHOT.to_s,
        "-q:v", "4", prefix
      ]
      _stdout, _stderr, status = Open3.capture3(*command)
      return [] unless status.success?

      Dir.glob(prefix.sub("%02d", "*")).sort.first(FRAMES_PER_SHOT)
    end

    def data_url(path)
      "data:image/jpeg;base64,#{Base64.strict_encode64(File.binread(path))}"
    end

    def normalize(parsed, expected_ids)
      rows = Array(parsed.is_a?(Hash) ? (parsed["shots"] || parsed[:shots]) : nil).filter_map do |item|
        next unless item.respond_to?(:to_h)
        row = item.to_h.stringify_keys
        next unless expected_ids.include?(row["shot_id"].to_s)

        overall = row["overall_score"].to_i.clamp(0, 100)
        row["overall_score"] = overall
        row["audit_status"] = "measured"
        row["issues"] = Array(row["issues"]).map(&:to_s)
        DIMENSION_THRESHOLDS.each_key { |key| row[key] = row[key].to_i.clamp(0, 100) }
        row["hard_failures"] = DIMENSION_THRESHOLDS.filter_map do |key, threshold|
          "#{key}=#{row[key]} below #{threshold}" if row[key] < threshold
        end
        row["hard_failures"] << "critical visible inconsistency" if row["issues"].any? { |text| critical_issue?(text) }
        row["hard_failures"].uniq!
        row["model_pass"] = ActiveRecord::Type::Boolean.new.cast(row["pass"])
        # Scores and explicit hard constraints are the deterministic contract.
        # A model boolean may not veto its own passing scores for a qualified
        # "minor" observation; keep it only as diagnostic evidence.
        row["pass"] = overall >= PASS_THRESHOLD && row["hard_failures"].empty?
        row
      end
      missing_ids = expected_ids - rows.map { |row| row["shot_id"].to_s }
      rows.concat(missing_ids.map do |shot_id|
        unavailable_row(shot_id, "vision evaluator omitted this shot")
      end)
      { "status" => "measured", "shots" => rows }
    end

    def critical_issue?(text)
      clauses = text.to_s.split(/[.;]/).map(&:strip).reject(&:empty?)
      clauses.any? do |clause|
        clause.match?(ABSOLUTE_CRITICAL_ISSUE_PATTERN) ||
          (clause.match?(MORPH_ISSUE_PATTERN) && !clause.match?(MINOR_QUALIFIER_PATTERN))
      end
    end

    def unavailable(reason)
      { "status" => "not_measured", "reason" => reason.to_s }
    end
  end
end
