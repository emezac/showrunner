# frozen_string_literal: true

require "prompt_copilot"

class ProjectsController < ApplicationController
  ASSET_COLLECTIONS = %w[characters props locations].freeze

  before_action :set_user_and_account
  before_action :set_project, only: [:show, :destroy, :approve_storyboard, :render_video, :regenerate_scene, :regenerate_shot, :generate_variant, :update_metadata, :regenerate_asset_image, :regenerate_shot_image, :regenerate_scene_images, :rerun_visual_qa]

  def index
    @projects = @current_user.projects.order(created_at: :desc)
    @new_project = Project.new(dry_run: false)
  end

  def show
    @manifest = (@project.manifest || {}).deep_dup
    stored_screenplay = @manifest.dig("screenplay") || {}
    if Array(stored_screenplay["scenes"]).any?
      stored_screenplay = ScreenplayPlanner.upgrade!(
        stored_screenplay,
        target_duration: @project.duration,
        max_scenes: nil,
        seed: @project.seed
      )
      stored_screenplay = StoryboardPromptCompiler.compile!(stored_screenplay)
      @manifest["screenplay"] = stored_screenplay
      @manifest["edit_decision_list"] = stored_screenplay["edit_decision_list"]
      @manifest["screenplay_quality_report"] ||= ScreenplayEvaluator.evaluate(
        stored_screenplay, target_duration: @project.duration
      )
    end
    CanonicalMediaStore.prefer_stable_for_display!(@manifest)
    @story_display = @manifest.dig("story", "display") || {}
    @reasoning = @manifest.dig("reasoning") || {}
    @quality_meter = @manifest.dig("quality_meter") || {}
    @coherence = @manifest.dig("coherence_metrics") || {}
    @screenplay = @manifest.dig("screenplay") || {}
    @budget_ledger = @manifest.dig("budget_ledger") || {}
    @preproduction_checkpoint_stage = PreproductionCheckpoint.stage_for(@project)
    @preproduction_checkpoint = @manifest.dig("preproduction_checkpoint") || {}
  end

  def create
    @project = @current_user.projects.new(project_params)
    mode_policy = ProductionModePolicy.resolve(input: requested_direction, prompt: @project.prompt)
    @project.direction = mode_policy["direction"]
    token_forecast = ProductionTokenPredictor.estimate(
      input: production_forecast_input.merge(@project.direction.slice(
        "pipeline_mode", "adaptation_mode", "genre", "camera_style", "color_grade",
        "music_style", "voice_style", "max_scenes"
      )),
      history_scope: @current_user.projects
    )
    forecast_approved = ProductionTokenPredictor.approval_valid?(
      forecast: token_forecast,
      supplied_digest: params[:token_forecast_digest],
      approved: params[:approve_token_overrun]
    )
    requires_forecast_approval = @project.prompt.present? && token_forecast["overrun_required"]
    
    @project.direction = @project.direction.merge(
      "token_forecast" => token_forecast,
      "production_token_overrun_authorized" => requires_forecast_approval && forecast_approved,
      "production_token_overrun_digest" => (token_forecast["approval_digest"] if requires_forecast_approval && forecast_approved),
      "production_token_overrun_approved_at" => (Time.current.iso8601 if requires_forecast_approval && forecast_approved)
    ).compact

    @project.status = "planning"
    @project.seed = params[:seed].presence || rand(1_000_000)

    mode_policy["errors"].each { |message| @project.errors.add(:direction, message) }

    if mode_policy["errors"].any?
      @projects = @current_user.projects.order(created_at: :desc)
      @new_project = @project
      render :index, status: :unprocessable_entity
    elsif requires_forecast_approval && !forecast_approved
      @project.errors.add(
        :token_budget,
        "is below the predicted safe budget of #{token_forecast['recommended_budget']} tokens; approve the estimated overrun or increase the budget"
      )
      @projects = @current_user.projects.order(created_at: :desc)
      @new_project = @project
      render :index, status: :unprocessable_entity
    elsif @project.save
      # Encolamos la planificación mediante el job de AgentKit
      Agentkit::AgentWorkerJob.perform_later(
        "ShowrunnerAgent",
        "Project",
        @project.id,
        @current_user.id
      )
      redirect_to @project, notice: "Showrunner started. Planning story..."
    else
      @projects = @current_user.projects.order(created_at: :desc)
      @new_project = @project
      render :index, status: :unprocessable_entity
    end
  end

  def destroy
    processing = %w[planning rendering].include?(@project.status)
    @project.destroy
    notice = if processing
               "Project deleted. Running production was cancelled; no additional provider requests will be started."
             else
               "Project deleted."
             end
    redirect_to projects_url, notice: notice
  end

  def approve_storyboard
    return unless full_control_configuration_ready?

    manifest = (@project.manifest || {}).with_indifferent_access
    consistency = manifest["consistency_report"] || {}
    if consistency_gate_blocked?(manifest, consistency)
      redirect_to @project, alert: "Consistency gate failed. Resolve canonical asset or storyboard issues before rendering."
    elsif @project.status == "awaiting_storyboard_approval"
      forecast_overrun = ProductionTokenPredictor.authorization_valid_for_project?(@project)
      allow_overrun = token_overrun_authorized? || forecast_overrun
      if @project.tokens_remaining.to_i <= 0 && !allow_overrun
        redirect_to @project, alert: "Token budget is exhausted. Enable ‘Allow Spending Beyond the Token Limit’ before starting video production."
        return
      end
      manifest = (@project.manifest || {}).with_indifferent_access
      manifest["render_token_overrun"] = one_shot_overrun_authorization(
        source: forecast_overrun ? "production_token_forecast" : "manual"
      ) if allow_overrun
      @project.update!(status: "rendering", manifest: manifest)
      ProduceDramaJob.perform_later(@project.id)
      redirect_to @project, notice: "Storyboard approved. Starting video synthesis..."
    else
      redirect_to @project, alert: "Project status not eligible for approval."
    end
  end

  def render_video
    return unless full_control_configuration_ready?

    unless %w[awaiting_storyboard_approval failed completed].include?(@project.status)
      redirect_to @project, alert: "Project is already processing."
      return
    end

    manifest = (@project.manifest || {}).with_indifferent_access
    consistency = manifest["consistency_report"] || {}
    override_requested = ActiveRecord::Type::Boolean.new.cast(params[:allow_visual_qa_override])
    video_recovery_requested = ActiveRecord::Type::Boolean.new.cast(params[:retry_video_qa])
    if override_requested && pending_video_recoverable?(manifest)
      finalize_pending_video!(manifest)
      redirect_to @project, notice: "Existing final cut approved with an explicit visual-risk acceptance. No new tokens or video credits were used."
      return
    end

    forecast_overrun = ProductionTokenPredictor.authorization_valid_for_project?(@project)
    allow_overrun = token_overrun_authorized? || forecast_overrun
    if @project.tokens_remaining.to_i <= 0 && !allow_overrun
      redirect_to @project, alert: "Token budget is exhausted. Enable ‘Allow Spending Beyond the Token Limit’ before starting video production."
      return
    end

    override_applied = false
    if consistency_gate_blocked?(manifest, consistency)
      targeted_video_recovery = video_recovery_requested &&
        video_consistency_gate_blocked?(manifest) &&
        storyboard_ready_for_video_recovery?(manifest, consistency)
      overrideable = ConsistencyOverridePolicy.overrideable?(consistency) || video_visual_overrideable?(manifest)
      unless targeted_video_recovery || (override_requested && overrideable)
        redirect_to @project, alert: "Consistency gate failed. Regenerate failed frames, retry visual or final-video QA, repair failed clips, or explicitly accept visual-QA risk."
        return
      end

      if override_requested
        ConsistencyOverridePolicy.authorize!(manifest: manifest, screenplay: manifest["screenplay"] || {})
        override_applied = true
      end
    end

    if video_recovery_requested && ConsistencyOverridePolicy.legacy_checkpoint_unchanged?(
      manifest: manifest, project_updated_at: @project.updated_at
    )
      ConsistencyOverridePolicy.authorize_legacy_clip_recovery!(manifest: manifest)
    end

    manifest["render_token_overrun"] = one_shot_overrun_authorization(
      source: forecast_overrun ? "production_token_forecast" : "manual"
    ) if allow_overrun
    @project.manifest = manifest
    @project.status = "rendering"
    @project.save!
    ProduceDramaJob.perform_later(@project.id)
    notice = if override_applied
               "Starting rendering with an explicit one-render visual-QA authorization..."
             elsif video_recovery_requested
               "Reusing approved clips, repairing only failed clips, and retrying final-video QA..."
             else
               "Starting rendering..."
             end
    redirect_to @project, notice: notice
  end

  # Modifica un prompt visual de un Shot específico
  def regenerate_shot
    shot_id = params[:shot_id]
    modifier = params[:modifier].to_s.strip

    manifest = @project.manifest || {}
    screenplay = manifest["screenplay"] || {}
    scenes = screenplay["scenes"] || []

    # Buscamos el shot en el manifest
    found_shot = nil
    scenes.each do |scene|
      scene["shots"].each do |shot|
        if shot["id"] == shot_id
          found_shot = shot
          break
        end
      end
    end

    if found_shot
      base_prompt = found_shot["source_visual_prompt"].presence || ConsistencyEnforcer.strip_consistency_suffix(found_shot["visual_prompt"].to_s)
      updated_prompt = modifier.present? ? "#{base_prompt}, #{modifier}" : base_prompt
      found_shot["source_visual_prompt"] = updated_prompt
      found_shot["visual_prompt"] = updated_prompt
      rebuild_manifest_consistency_for_project!(manifest)
      manifest["consistency_report"] ||= {}
      manifest["consistency_report"]["visual_metrics"] = {
        "status" => "not_measured",
        "reason" => "shot prompt changed after visual audit"
      }
      invalidate_video_artifacts!(manifest)
      @project.manifest = manifest
      @project.save!

      # Si se solicita regenerar el video inmediatamente en sandbox
      if params[:render_now] == "true"
        @project.update!(status: "rendering")
        ProduceDramaJob.perform_later(@project.id)
        redirect_to @project, notice: "Prompt modified. Rendering..."
      else
        redirect_to @project, notice: "Shot #{shot_id} modified in screenplay."
      end
    else
      redirect_to @project, alert: "Shot not found."
    end
  end

  # Copiloto creativo para sugerir prompts
  def copilot_suggest
    prompt = params[:prompt].to_s.strip
    if prompt.length < 5
      render json: { suggestions: [] }
      return
    end

    # Ledger separado de asistencias de UI
    ledger = { tokens_used: 0 }
    
    system_prompt = "You are a creative cinema assistant. The user is writing a dramatic story prompt. " \
                    "Suggest 3 short ideas of 3 to 5 words in English to add drama, twists, horror, or emotion. " \
                    "Return EXCLUSIVELY JSON: {\"suggestions\": [\"suggestion 1\", \"suggestion 2\", \"suggestion 3\"]}"

    begin
      parsed, = QwenRouter.call_json(
        system: system_prompt,
        user: "Current prompt: #{prompt}",
        stage: :suggest,
        max_tokens: 60,
        config: QwenRouter::Config.default
      )
      
      # Loggeamos el uso de tokens en la tabla ui_assist
      if parsed.is_a?(Hash) && parsed["suggestions"]
        UiAssistLedgerEntry.create!(project_id: params[:project_id].presence || Project.last&.id, tokens_used: 50)
        render json: { suggestions: parsed["suggestions"] }
      else
        offline_sug = PromptCopilot.suggest_offline(prompt)
        render json: { suggestions: offline_sug }
      end
    rescue => e
      # Silenciar y advertir de forma elegante si es un error de cuenta/suscripción de modelo
      if e.message.include?("AccessDenied.Unpurchased")
        Rails.logger.warn("[CopilotSuggest] Qwen text model not enabled/purchased on this account. Activating smart offline suggestions fallback.")
      else
        Rails.logger.warn("[CopilotSuggest] Qwen cloud call failed: #{e.message}. Using smart offline suggestions fallback.")
      end
      
      offline_sug = PromptCopilot.suggest_offline(prompt)
      render json: { suggestions: offline_sug }
    end
  end

  def forecast_tokens
    mode_policy = ProductionModePolicy.resolve(input: requested_direction, prompt: production_forecast_input[:prompt])
    forecast = ProductionTokenPredictor.estimate(
      input: production_forecast_input.merge(mode_policy["direction"].slice(
        "pipeline_mode", "adaptation_mode", "genre", "camera_style", "color_grade",
        "music_style", "voice_style", "max_scenes"
      )),
      history_scope: @current_user.projects
    )
    render json: forecast.merge(
      "configuration_errors" => mode_policy["errors"],
      "automatic_defaults" => mode_policy["resolved_defaults"]
    )
  rescue StandardError => e
    Rails.logger.error("Production token forecast failed: #{e.class}: #{e.message}")
    render json: { status: "error", message: "Token forecast unavailable" }, status: :unprocessable_entity
  end

  # Regenera una escena completa con modificadores dramáticos
  def regenerate_scene
    scene_index = params[:scene_index].to_i
    manifest = @project.manifest || {}
    screenplay = manifest["screenplay"] || {}
    scenes = screenplay["scenes"] || []

    if scene = scenes[scene_index]
      # Aplicar un modificador visual dramático a todos los planos de esta escena
      scene["shots"].each do |shot|
        base_prompt = shot["source_visual_prompt"].presence || ConsistencyEnforcer.strip_consistency_suffix(shot["visual_prompt"].to_s)
        shot["source_visual_prompt"] = "#{base_prompt}, dramatic lighting cinematic"
        shot["visual_prompt"] = shot["source_visual_prompt"]
      end
      rebuild_manifest_consistency_for_project!(manifest)
      manifest["consistency_report"] ||= {}
      manifest["consistency_report"]["visual_metrics"] = {
        "status" => "not_measured",
        "reason" => "storyboard scene changed after visual audit"
      }
      invalidate_video_artifacts!(manifest)
      @project.manifest = manifest
      @project.save!
      redirect_to @project, notice: "Scene #{scene_index + 1} regenerated with additional plot twists."
    else
      redirect_to @project, alert: "Scene not found."
    end
  end

  # Crea un final alternativo / clonación del proyecto
  def generate_variant
    variant = @project.dup
    variant.seed = rand(1_000_000)
    variant.prompt = "#{@project.prompt} (Variant with surprising ending)"
    variant.status = "planning"
    variant.title = "#{@project.title} (Alternative Cut)"
    variant.save!

    Agentkit::AgentWorkerJob.perform_later(
      "ShowrunnerAgent",
      "Project",
      variant.id,
      @current_user.id
    )
    redirect_to variant, notice: "New alternative variant started."
  end

  # Actualiza metadatos interactivos del storyboard (genes, dirección, duración)
  def update_metadata
    manifest = @project.manifest || {}
    manifest = manifest.with_indifferent_access
    previous_visual_metrics = manifest.dig("consistency_report", "visual_metrics")&.deep_dup
    visual_contract_changed = params[:screenplay].present? || params[:assets].present?

    # 1. Update genes
    if params[:genes].is_a?(Array)
      manifest["story"] ||= {}
      manifest["story"]["preserved_genes"] = params[:genes]
    end

    # 2. Update direction
    if params[:direction].is_a?(Hash)
      new_direction = params[:direction].permit(
        :director_influence, :camera_style, :color_grade, :music_style, :voice_style,
        :force_story, :force_domain, :pipeline_mode, :genre
      ).to_h.compact
      @project.direction = (@project.direction || {}).merge(new_direction)
    end

    # 3. Update screenplay content edits
    if params[:screenplay].is_a?(Hash) && params[:screenplay][:scenes].is_a?(Array)
      screenplay = manifest["screenplay"] || {}
      existing_scenes = screenplay["scenes"] || []

      params[:screenplay][:scenes].each_with_index do |scene_params, sc_idx|
        next unless existing_scenes[sc_idx]

        # Scene-level dramatic contract
        existing_scenes[sc_idx]["heading"] = scene_params[:heading] if scene_params[:heading].present?
        existing_scenes[sc_idx]["action"] = scene_params[:action] if scene_params[:action].present?
        %i[objective conflict turn outcome].each do |field|
          existing_scenes[sc_idx][field.to_s] = scene_params[field] if scene_params[field].present?
        end

        # Dialogue list
        if scene_params[:dialogue].is_a?(Array)
          existing_dialogue = existing_scenes[sc_idx]["dialogue"] || []
          scene_params[:dialogue].each_with_index do |dlg_params, dlg_idx|
            next unless existing_dialogue[dlg_idx]
            existing_dialogue[dlg_idx]["character"] = dlg_params[:character] if dlg_params[:character].present?
            existing_dialogue[dlg_idx]["line"] = dlg_params[:line] if dlg_params[:line].present?
          end
        end

        # Shots list
        if scene_params[:shots].is_a?(Array)
          existing_shots = existing_scenes[sc_idx]["shots"] || []
          scene_params[:shots].each do |shot_params|
            if found = existing_shots.find { |s| s["id"].to_s == shot_params[:id].to_s }
              if shot_params[:visual_prompt].present?
                found["source_visual_prompt"] = shot_params[:visual_prompt]
                found["visual_prompt"] = shot_params[:visual_prompt]
              end
              found["camera"] = shot_params[:camera] if shot_params[:camera].present?

              # Sync visual_prompt directly to Shot DB record
              @project.shots.find_by(shot_id: shot_params[:id].to_s)&.update!(
                visual_prompt: shot_params[:visual_prompt]
              )
            end
          end
        end
      end
    end

    # 4. Update durations and locks
    screenplay = manifest["screenplay"] || {}
    scenes = screenplay["scenes"] || []

    if params[:shot_durations].is_a?(Hash)
      params[:shot_durations].each do |shot_id, duration|
        val = duration.to_i
        next if val < 2 || val > 10

        scenes.each do |scene|
          scene["shots"]&.each do |shot|
            if shot["id"].to_s == shot_id.to_s
              shot["duration"] = val
            end
          end
        end

        @project.shots.find_by(shot_id: shot_id)&.update!(duration: val)
      end
    end

    if params[:locks].is_a?(Hash)
      params[:locks].each do |shot_id, locked|
        val = ActiveRecord::Type::Boolean.new.cast(locked)
        scenes.each do |scene|
          scene["shots"]&.each do |shot|
            if shot["id"].to_s == shot_id.to_s
              shot["locked"] = val
            end
          end
        end

        @project.shots.find_by(shot_id: shot_id)&.update!(locked: val)
      end
    end

    # Recompile timing and edit decisions after any script, camera or duration
    # edit, even when the project has no canonical asset records yet.
    if manifest["screenplay"].present?
      manifest["screenplay"] = ScreenplayPlanner.upgrade!(
        manifest["screenplay"],
        target_duration: @project.duration,
        max_scenes: nil,
        seed: @project.seed
      )
      manifest["screenplay"] = StoryboardPromptCompiler.compile!(manifest["screenplay"])
      manifest["edit_decision_list"] = manifest["screenplay"]["edit_decision_list"]
      manifest["screenplay_quality_report"] = ScreenplayEvaluator.evaluate(
        manifest["screenplay"], target_duration: @project.duration
      )
      shot_records = @project.shots.index_by { |record| record.shot_id.to_s }
      Array(manifest["screenplay"]["scenes"]).each do |scene|
        Array(scene["shots"]).each do |shot|
          record = shot_records[shot["id"].to_s]
          record&.update!(duration: shot["duration"], visual_prompt: shot["source_visual_prompt"] || shot["visual_prompt"])
        end
      end
    end

    # 5. Update assets
    if params[:assets].is_a?(Hash)
      manifest["assets"] ||= {}
      
      # Characters update
      if params[:assets][:characters].is_a?(Array)
        manifest["assets"]["characters"] ||= []
        params[:assets][:characters].each do |char_params|
          found = manifest["assets"]["characters"].find { |c| c["id"].to_s == char_params[:id].to_s }
          if found
            found["name"] = char_params[:name] if char_params[:name].present?
            found["physical_description"] = char_params[:physical_description] if char_params[:physical_description].present?
            found["personality_traits"] = char_params[:personality_traits] if char_params[:personality_traits].present?
            found["unique_behavior"] = char_params[:unique_behavior] if char_params[:unique_behavior].present?
            found["visual_prompt"] = char_params[:visual_prompt] if char_params[:visual_prompt].present?
            found["image_url"] = char_params[:image_url] if char_params[:image_url].present?
          end
        end
      end

      # Locations update
      if params[:assets][:locations].is_a?(Array)
        manifest["assets"]["locations"] ||= []
        params[:assets][:locations].each do |loc_params|
          found = manifest["assets"]["locations"].find { |l| l["id"].to_s == loc_params[:id].to_s }
          if found
            found["name"] = loc_params[:name] if loc_params[:name].present?
            found["description"] = loc_params[:description] if loc_params[:description].present?
            found["lighting"] = loc_params[:lighting] if loc_params[:lighting].present?
            found["atmosphere"] = loc_params[:atmosphere] if loc_params[:atmosphere].present?
            found["visual_prompt"] = loc_params[:visual_prompt] if loc_params[:visual_prompt].present?
            found["image_url"] = loc_params[:image_url] if loc_params[:image_url].present?
          end
        end
      end

      # Recurring props/objects update. Props use the same canonical asset
      # contract as characters so any project can lock products, vehicles,
      # weapons, tools, balls, documents or other story-critical objects.
      if params[:assets][:props].is_a?(Array)
        manifest["assets"]["props"] ||= []
        params[:assets][:props].each do |prop_params|
          found = manifest["assets"]["props"].find { |prop| prop["id"].to_s == prop_params[:id].to_s }
          next unless found

          %i[name description color material dimensions visual_prompt image_url scale_reference].each do |field|
            found[field.to_s] = prop_params[field] if prop_params[field].present?
          end
          %i[physical_constraints behavior_constraints immutable_traits forbidden_mutations].each do |field|
            next unless prop_params[field].is_a?(Array)

            found[field.to_s] = prop_params[field].map(&:to_s).map(&:strip).reject(&:blank?).uniq
          end
        end
      end

      # Re-apply ConsistencyEnforcer using updated assets
      screenplay = manifest["screenplay"] || {}
      config = {
        prompt:          @project.prompt,
        target_duration: @project.duration,
        resolution:      @project.resolution,
        token_budget:    @project.token_budget,
        seed:            @project.seed,
        adaptation_mode: @project.direction&.dig("adaptation_mode") || "faithful"
      }
      engine = ShowrunnerEngine.new(config: config)
      engine.resolve_story!
      is_rich = Screenwriter.parse_scenes_from_prompt(@project.prompt).present? || @project.prompt.to_s.strip.length > 800
      manifest["screenplay"] = ConsistencyEnforcer.apply!(screenplay, engine.selection, manifest["assets"], rich_prompt: is_rich)
    end

    # Rebuild continuity after any user edit. This is deterministic and does
    # not consume model credits.
    if manifest["screenplay"].present? && manifest["assets"].present?
      config = {
        prompt: @project.prompt,
        target_duration: @project.duration,
        resolution: @project.resolution,
        token_budget: @project.token_budget,
        seed: @project.seed,
        adaptation_mode: @project.direction&.dig("adaptation_mode") || "faithful"
      }
      engine = ShowrunnerEngine.new(config: config)
      engine.resolve_story!
      manifest["screenplay"] = ScreenplayPlanner.upgrade!(
        manifest["screenplay"],
        target_duration: @project.duration,
        max_scenes: nil,
        seed: @project.seed
      )
      manifest["screenplay"] = StoryboardPromptCompiler.compile!(manifest["screenplay"])
      production_bible = ProductionBible.compile(
        screenplay: manifest["screenplay"],
        assets: manifest["assets"],
        selection: engine.selection,
        original_prompt: @project.prompt
      )
      manifest["screenplay"] = ContinuityPlanner.plan!(manifest["screenplay"], production_bible)
      manifest["screenplay"] = ConsistencyEnforcer.apply!(
        manifest["screenplay"], engine.selection, manifest["assets"], production_bible: production_bible
      )
      manifest["production_bible"] = production_bible
      manifest["edit_decision_list"] = manifest["screenplay"]["edit_decision_list"]
      manifest["screenplay_quality_report"] = ScreenplayEvaluator.evaluate(
        manifest["screenplay"], target_duration: @project.duration
      )
      manifest["consistency_report"] = ConsistencyEvaluator.evaluate(
        screenplay: manifest["screenplay"], production_bible: production_bible, assets: manifest["assets"],
        strict_references: !@project.dry_run?
      )
      if previous_visual_metrics.present? && !visual_contract_changed
        manifest["consistency_report"]["visual_metrics"] = previous_visual_metrics
      elsif visual_contract_changed
        manifest["consistency_report"]["visual_metrics"] = {
          "status" => "not_measured",
          "reason" => "screenplay or canonical asset changed after visual audit"
        }
      end
    end

    # 4. Recompose metrics
    display_info = DisplayComposer.compose(manifest)
    manifest["story"] ||= {}
    manifest["story"]["display"] = display_info[:display]
    manifest["reasoning"] = display_info[:reasoning]
    manifest["quality_meter"] = display_info[:quality_meter]
    manifest["coherence_metrics"] = display_info[:coherence_metrics]
    invalidate_video_artifacts!(manifest) if visual_contract_changed || params[:direction].present? || params[:shot_durations].present?

    @project.manifest = manifest
    @project.title = display_info.dig(:display, :title) || @project.title
    @project.save!

    render json: {
      status: "success",
      title: @project.title,
      display: display_info[:display],
      reasoning: display_info[:reasoning],
      quality_meter: display_info[:quality_meter],
      coherence_metrics: display_info[:coherence_metrics],
      direction: @project.direction,
      shot_durations: Array(manifest.dig("screenplay", "scenes")).flat_map { |scene| Array(scene["shots"]) }
        .to_h { |shot| [ shot["id"].to_s, shot["duration"] ] },
      edit_decision_list: manifest["edit_decision_list"],
      screenplay_quality_report: manifest["screenplay_quality_report"]
    }
  end

  def architecture
    @architecture_version = ProduceDramaJob::RUNTIME_VERSION
    @visual_pass_threshold = VisualConsistencyEvaluator::PASS_THRESHOLD
    @visual_dimension_thresholds = VisualConsistencyEvaluator::DIMENSION_THRESHOLDS
    @pipeline_stages = [
      ["01", "Narrative contract", "Validate the source, resolve contradictions, estimate cost and lock production mode."],
      ["02", "Canonical visual bible", "Extract recurring entities, scale, materials, identity, physics and permitted agency."],
      ["03", "Storyboard contract", "Compile atomic shots, continuity states, reference plates, timing and the edit decision list."],
      ["04", "Storyboard visual QA", "Measure identity, props, scale and physical plausibility before paid video synthesis."],
      ["05", "Video production", "Select I2V/R2V/T2V per shot, reuse checkpoints and perform one bounded repair pass."],
      ["06", "Edit and delivery", "Mix required audio, assemble with FFmpeg, run final-video QA and publish the recoverable cut."]
    ]
  end

  def regenerate_asset_image
    manifest = (@project.manifest || {}).deep_dup.with_indifferent_access
    asset_id = params[:asset_id].to_s
    asset_type = params[:asset_type].to_s
    allow_token_overrun = token_overrun_authorized?

    unless ASSET_COLLECTIONS.include?(asset_type)
      render json: { status: "error", message: "Unsupported asset type" }, status: :unprocessable_entity
      return
    end

    repair = AssetProfiler.repair_source_contract!(
      manifest["screenplay"] || {}, @project, manifest["assets"] || {}, selection: nil
    )
    manifest["assets"] = repair["assets"]
    asset = Array(manifest.dig("assets", asset_type)).find { |candidate| candidate["id"].to_s == asset_id }
    unless asset
      render json: { status: "error", message: "Asset not found" }, status: :not_found
      return
    end

    previous_url = asset["image_url"].to_s
    generated_at = Time.current.to_f
    if @project.dry_run?
      encoded_svg = ERB::Util.url_encode(dry_run_asset_svg(asset, generated_at)).gsub("+", "%20")
      asset["image_url"] = "data:image/svg+xml;charset=utf-8,#{encoded_svg}"
    else
      StoryboardRegenerator.ensure_project_visual_budget!(
        project: @project, shot_count: 1, allow_token_overrun: allow_token_overrun
      )
      generation_prompt = if asset_type == "characters"
                            AssetProfiler.character_reference_prompt(asset)
                          else
                            asset["visual_prompt"].presence || "Canonical reference of #{asset['name']}"
                          end
      reference_urls = canonical_regeneration_references(asset)
      job_result = HappyHorseClient.new.submit_with_retries(
        prompt: generation_prompt,
        mode: :t2i,
        reference_image_urls: reference_urls
      )
      new_url = job_result.image_url.to_s
      unless job_result.succeeded? && new_url.start_with?("http://", "https://") && new_url != previous_url
        render json: { status: "error", message: "Image provider did not return a new canonical frame" }, status: :unprocessable_entity
        return
      end
      asset["image_url"] = new_url
      @project.video_credits_used = @project.video_credits_used.to_i + 1
    end

    if asset["image_url"].to_s.start_with?("http://", "https://")
      asset["reference_images"] = ([asset["image_url"]] + canonical_regeneration_references(asset))
        .uniq.first(asset_type == "characters" ? 2 : 1)
    end
    CanonicalMediaStore.materialize_assets!(@project.id, manifest["assets"] || {}) unless @project.dry_run?

    rebuild_manifest_consistency_for_project!(manifest)
    manifest["consistency_report"] ||= {}
    manifest["consistency_report"]["visual_metrics"] = {
      "status" => "not_measured",
      "reason" => "canonical asset changed after visual audit"
    }
    invalidate_video_artifacts!(manifest)
    @project.manifest = manifest
    @project.save!

    render json: {
      status: "success", image_url: asset["image_url"], generated_at: generated_at,
      asset_id: asset_id, asset_type: asset_type, scale_reference: asset["scale_reference"],
      requires_storyboard_regeneration: true,
      consistency: consistency_payload(manifest["consistency_report"], manifest),
      budget: current_budget_payload(overrun_authorized: allow_token_overrun)
    }
  rescue StandardError => e
    Rails.logger.error("Canonical asset regeneration failed for project #{@project.id}: #{e.class}: #{e.message}")
    render json: { status: "error", message: e.message }, status: :unprocessable_entity
  end

  def regenerate_shot_image
    shot_id = params[:shot_id].to_s
    result = StoryboardRegenerator.regenerate!(
      project: @project, manifest: @project.manifest || {}, shot_ids: [shot_id], respect_locks: false,
      allow_token_overrun: token_overrun_authorized?
    )
    persist_regeneration_result!(result)
    image = result["images"].find { |item| item["shot_id"].to_s == shot_id }
    render json: regeneration_payload(result).merge(image_url: image&.dig("image_url"))
  rescue StandardError => e
    Rails.logger.error("Storyboard shot regeneration failed for project #{@project.id}: #{e.class}: #{e.message}")
    render json: { status: "error", message: e.message }, status: :unprocessable_entity
  end

  def regenerate_scene_images
    scene_idx = params[:scene_idx].to_i
    scene = Array((@project.manifest || {}).dig("screenplay", "scenes"))[scene_idx]
    unless scene
      render json: { status: "error", message: "Scene not found" }, status: :not_found
      return
    end
    shot_ids = Array(scene["shots"]).map { |shot| shot["id"].to_s }
    result = StoryboardRegenerator.regenerate!(
      project: @project, manifest: @project.manifest || {}, shot_ids: shot_ids, respect_locks: true,
      allow_token_overrun: token_overrun_authorized?
    )
    persist_regeneration_result!(result)
    render json: regeneration_payload(result)
  rescue StandardError => e
    Rails.logger.error("Storyboard scene regeneration failed for project #{@project.id}: #{e.class}: #{e.message}")
    render json: { status: "error", message: e.message }, status: :unprocessable_entity
  end

  def rerun_visual_qa
    result = StoryboardVisualQaRefresher.refresh!(
      project: @project,
      manifest: @project.manifest || {},
      allow_token_overrun: token_overrun_authorized?
    )
    persist_regeneration_result!(result)
    render json: regeneration_payload(result)
  rescue StandardError => e
    Rails.logger.error("Storyboard visual QA refresh failed for project #{@project.id}: #{e.class}: #{e.message}")
    render json: { status: "error", message: e.message }, status: :unprocessable_entity
  end

  def placeholder
    filename = params[:filename].to_s
    name = filename.titleize.gsub(".png", "").gsub("_", " ")
    
    # Check if character or location to style accordingly
    is_char = filename.start_with?("character")
    bg_color = is_char ? "#151722" : "#1a131b"
    accent_color = is_char ? "#e3a34d" : "#ec4899"
    icon = is_char ? 
      '<circle cx="100" cy="80" r="30" fill="currentColor"/><path d="M50 160c0-27.6 22.4-50 50-50s50 22.4 50 50v10H50v-10z" fill="currentColor"/>' :
      '<rect x="40" y="70" width="120" height="80" rx="6" fill="none" stroke="currentColor" stroke-width="4"/><path d="M40 130l30-30 30 30 40-40 20 20v20H40v-30z" fill="currentColor"/>'

    svg = <<~SVG
      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200" width="100%" height="100%">
        <rect width="100%" height="100%" fill="#{bg_color}"/>
        <g color="#{accent_color}" opacity="0.6">
          #{icon}
        </g>
        <text x="100" y="180" font-family="-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif" font-size="11" font-weight="bold" fill="#64748b" text-anchor="middle" letter-spacing="1">
          #{name.upcase}
        </text>
      </svg>
    SVG

    send_data svg, type: 'image/svg+xml', disposition: 'inline'
  end

  private

  def persist_regeneration_result!(result)
    ledger = result["ledger"] || {}
    manifest = result["manifest"].with_indifferent_access
    unless @project.dry_run?
      CanonicalMediaStore.materialize_assets!(@project.id, manifest["assets"] || {})
      CanonicalMediaStore.materialize_screenplay!(@project.id, manifest["screenplay"] || {})
    end
    @project.manifest = manifest
    @project.tokens_used = ledger[:tokens_used] || ledger["tokens_used"] || @project.tokens_used
    @project.tokens_remaining = ledger[:tokens_remaining] || ledger["tokens_remaining"] || @project.tokens_remaining
    @project.video_credits_used = ledger[:video_credits_used] || ledger["video_credits_used"] || @project.video_credits_used
    @project.save!
  end

  def regeneration_payload(result)
    report = result["consistency_report"] || {}
    ledger = result["ledger"] || {}
    {
      status: result["errors"].any? ? "partial" : "success",
      images: result["images"],
      asset_images: result["asset_images"],
      errors: result["errors"],
      skipped_shot_ids: result["skipped_shot_ids"],
      changed_asset_ids: result["changed_asset_ids"],
      generated_at: result["generated_at"],
      consistency: consistency_payload(report, result["manifest"] || {}),
      budget: {
        tokens_used: ledger[:tokens_used] || ledger["tokens_used"] || @project.tokens_used,
        tokens_remaining: ledger[:tokens_remaining] || ledger["tokens_remaining"] || @project.tokens_remaining,
        token_budget: ledger[:token_budget] || ledger["token_budget"] || @project.token_budget,
        tokens_over_budget: ledger[:tokens_over_budget] || ledger["tokens_over_budget"] || 0,
        video_credits_used: ledger[:video_credits_used] || ledger["video_credits_used"] || @project.video_credits_used,
        overrun_authorized: ledger[:overrun_authorized] || ledger["overrun_authorized"] || false
      }
    }
  end

  def consistency_payload(report, manifest)
    report ||= {}
    manifest ||= {}
    {
      ready_for_render: report["ready_for_render"],
      structural_score: report["structural_score"],
      fidelity_score: report.dig("asset_fidelity", "score"),
      visual_status: report.dig("visual_metrics", "status"),
      visual_score: report.dig("visual_metrics", "average_score"),
      visual_reason: report.dig("visual_metrics", "recheck_reason").presence || report.dig("visual_metrics", "reason"),
      failed_shot_ids: report.dig("visual_metrics", "failed_shot_ids") || [],
      visual_override_applied: visual_override_active?(manifest, report),
      partial_shots_evaluated: Array(report.dig("visual_metrics", "partial_shots")).size,
      total_shots: Array((manifest["screenplay"] || {}).dig("scenes")).sum { |scene| Array(scene["shots"]).size },
      critical_count: report["critical_count"],
      script_status: report.dig("script_consistency", "status") || "not_checked",
      script_ready: report.dig("script_consistency", "ready"),
      script_resolved_count: report.dig("script_consistency", "resolved_count") || 0,
      script_critical_count: report.dig("script_consistency", "critical_count") || 0
    }
  end

  def canonical_regeneration_references(asset)
    qa_urls = (
      Array(asset["stable_qa_reference_images"]) + [asset["stable_scale_calibration_image_url"]] +
      Array(asset["qa_reference_images"]) + [asset["scale_calibration_image_url"]]
    ).compact.map(&:to_s)
    (
      Array(asset["stable_reference_images"]) + [asset["stable_image_url"]] +
      Array(asset["reference_images"]) + [asset["image_url"]]
    ).compact.map(&:to_s)
      .select { |url| StableMedia.reference?(url) }
      .reject { |url| qa_urls.include?(url) }
      .uniq.first(4)
  end

  def dry_run_asset_svg(asset, generated_at)
    label = ERB::Util.html_escape(asset["name"].presence || "Canonical asset")
    <<~SVG.squish
      <svg xmlns="http://www.w3.org/2000/svg" width="1280" height="720" viewBox="0 0 1280 720">
        <rect width="1280" height="720" fill="#11151a"/>
        <circle cx="640" cy="300" r="112" fill="#2a323b" stroke="#e3a34d" stroke-width="8"/>
        <text x="640" y="500" fill="#f3eee4" font-family="sans-serif" font-size="44" text-anchor="middle">#{label}</text>
        <text x="640" y="560" fill="#8d939e" font-family="monospace" font-size="24" text-anchor="middle">Dry-run reference #{generated_at.to_i}</text>
      </svg>
    SVG
  end

  def consistency_gate_blocked?(manifest, consistency)
    return true if consistency["ready_for_render"] == false

    failed_ids = Array(consistency.dig("visual_metrics", "failed_shot_ids"))
    (failed_ids.any? && !visual_override_active?(manifest, consistency)) || video_consistency_gate_blocked?(manifest)
  end

  def video_consistency_gate_blocked?(manifest)
    report = manifest.to_h.with_indifferent_access["video_consistency_report"].to_h
    return false if ActiveRecord::Type::Boolean.new.cast(report["override_applied"])

    Array(report["failed_shot_ids"]).any? || (report["status"].present? && report["status"] != "measured")
  end

  def video_visual_overrideable?(manifest)
    report = manifest.to_h.with_indifferent_access["video_consistency_report"].to_h
    Array(report["failed_shot_ids"]).any? || (report["status"].present? && report["status"] != "measured")
  end

  def storyboard_ready_for_video_recovery?(manifest, consistency)
    return false if consistency["ready_for_render"] == false

    visual = consistency["visual_metrics"].to_h
    return false unless visual["status"] == "measured"

    failed_ids = Array(visual["failed_shot_ids"])
    failed_ids.empty? || visual_override_active?(manifest, consistency)
  end

  def pending_video_recoverable?(manifest)
    pending = manifest["pending_video_review"].to_h
    expected_url = "/dramas/drama_#{@project.id}.mp4"
    return false unless ActiveRecord::Type::Boolean.new.cast(pending["available"])
    return false unless pending["url"] == expected_url
    return false unless ConsistencyOverridePolicy.render_checkpoint_matches?(
      manifest: manifest, project_updated_at: @project.updated_at
    )

    path = Rails.root.join("public", expected_url.delete_prefix("/"))
    File.file?(path) && File.size(path).positive? &&
      ActiveSupport::SecurityUtils.secure_compare(
        pending["video_sha256"].to_s,
        Digest::SHA256.file(path).hexdigest
      )
  rescue ArgumentError, Errno::ENOENT
    false
  end

  def finalize_pending_video!(manifest)
    pending = manifest["pending_video_review"].to_h
    report = manifest["video_consistency_report"].to_h
    report["override_applied"] = true
    report["override_scope"] = "existing_final_cut"
    report["override_accepted_at"] = Time.current.iso8601
    report["warnings"] = Array(report["warnings"]) + [
      "Producer explicitly accepted final-video visual-QA risk for this exact assembled cut."
    ]
    manifest["video_consistency_report"] = report
    manifest.delete("pending_video_review")
    manifest.delete("visual_qa_override")
    @project.update!(
      status: "completed",
      final_video_url: pending["url"],
      manifest: manifest
    )
    ActionCable.server.broadcast(
      "project_#{@project.id}",
      { type: "status", status: "completed", video_url: @project.final_video_url }
    )
  end

  def invalidate_video_artifacts!(manifest)
    manifest.delete("video_consistency_report")
    manifest.delete("video_jobs")
    manifest.delete("pending_video_review")
  end

  def visual_override_active?(manifest, consistency)
    applied = ActiveRecord::Type::Boolean.new.cast(consistency&.dig("visual_qa_override", "applied"))
    return false unless applied

    source = manifest.to_h.with_indifferent_access
    ConsistencyOverridePolicy.valid?(
      manifest: source,
      screenplay: source["screenplay"] || {}
    )
  end

  def token_overrun_authorized?
    ActiveRecord::Type::Boolean.new.cast(params[:allow_token_overrun])
  end

  def one_shot_overrun_authorization(source: "manual")
    {
      "authorized" => true,
      "scope" => "next_video_render",
      "source" => source,
      "authorized_at" => Time.current.iso8601
    }
  end

  def current_budget_payload(overrun_authorized: false)
    {
      tokens_used: @project.tokens_used.to_i,
      tokens_remaining: @project.tokens_remaining.to_i,
      token_budget: @project.token_budget.to_i,
      tokens_over_budget: [@project.tokens_used.to_i - @project.token_budget.to_i, 0].max,
      video_credits_used: @project.video_credits_used.to_i,
      overrun_authorized: overrun_authorized
    }
  end

  def production_forecast_input
    project_data = params[:project].respond_to?(:permit) ?
      params[:project].permit(:prompt, :duration, :resolution, :dry_run, :token_budget) :
      ActionController::Parameters.new
    {
      prompt: project_data[:prompt].presence || params[:prompt],
      duration: project_data[:duration].presence || params[:duration],
      resolution: project_data[:resolution].presence || params[:resolution],
      dry_run: project_data.key?(:dry_run) ? project_data[:dry_run] : params[:dry_run],
      token_budget: project_data[:token_budget].presence || params[:token_budget],
      pipeline_mode: params[:pipeline_mode],
      adaptation_mode: params[:adaptation_mode],
      genre: params[:genre],
      audience: params[:audience],
      brain_dump: params[:brain_dump],
      camera_style: params[:camera_style],
      color_grade: params[:color_grade],
      music_style: params[:music_style],
      voice_style: params[:voice_style],
      max_scenes: params[:max_scenes]
    }
  end

  def requested_direction
    {
      "director_influence" => params[:director_influence].presence,
      "camera_style" => params[:camera_style].presence,
      "color_grade" => params[:color_grade].presence,
      "music_style" => params[:music_style].presence,
      "voice_style" => params[:voice_style].presence,
      "force_story" => params[:force_story].presence,
      "force_domain" => params[:force_domain].presence,
      "max_scenes" => params[:max_scenes].present? ? params[:max_scenes].to_i : nil,
      "adaptation_mode" => params[:adaptation_mode].presence || "faithful",
      "genre" => params[:genre].presence,
      "audience" => params[:audience].presence,
      "brain_dump" => params[:brain_dump].presence,
      "pipeline_mode" => params[:pipeline_mode].presence || "agentic"
    }.compact
  end

  def full_control_configuration_ready?
    policy = ProductionModePolicy.resolve(input: @project.direction || {}, prompt: @project.prompt)
    return true if policy["errors"].empty?

    redirect_to @project, alert: "Full Control requires explicit choices before production: #{policy['errors'].join('; ')}."
    false
  end

  def rebuild_consistency_contract!(manifest, selection_source, screenplay)
    selection = selection_source.respond_to?(:selection) ? selection_source.selection : selection_source
    screenplay = ScreenplayPlanner.upgrade!(
      screenplay,
      target_duration: @project.duration,
      max_scenes: nil,
      seed: @project.seed
    )
    screenplay = StoryboardPromptCompiler.compile!(screenplay)
    production_bible = ProductionBible.compile(
      screenplay: screenplay,
      assets: manifest["assets"],
      selection: selection,
      original_prompt: @project.prompt
    )
    screenplay = ContinuityPlanner.plan!(screenplay, production_bible)
    screenplay = ConsistencyEnforcer.apply!(
      screenplay,
      selection,
      manifest["assets"],
      production_bible: production_bible
    )
    manifest["production_bible"] = production_bible
    manifest["screenplay"] = screenplay
    manifest["edit_decision_list"] = screenplay["edit_decision_list"]
    manifest["screenplay_quality_report"] = ScreenplayEvaluator.evaluate(
      screenplay,
      target_duration: @project.duration
    )
    manifest["consistency_report"] = ConsistencyEvaluator.evaluate(
      screenplay: screenplay,
      production_bible: production_bible,
      assets: manifest["assets"] || {},
      strict_references: !@project.dry_run?
    )
  end

  def rebuild_manifest_consistency_for_project!(manifest)
    rebuild_consistency_contract!(
      manifest,
      stored_story_selection(manifest),
      manifest["screenplay"] || {}
    )
  end

  def stored_story_selection(manifest)
    story = manifest["story"].to_h.with_indifferent_access
    character = Array(manifest.dig("assets", "characters")).first.to_h.with_indifferent_access
    prop = Array(manifest.dig("assets", "props")).first.to_h.with_indifferent_access
    genes = Array(story["preserved_genes"]).map { |gene| gene.to_s.to_sym }
    domain_key = (story["domain"].presence || "unspecified_setting").to_s.parameterize(separator: "_")
    domain_key = "unspecified_setting" if domain_key.blank?
    StoryEngine::Selection.new(
      base_story: {
        id: story["base_story_id"].presence || "faithful_prompt",
        archetype: :faithful_protagonist,
        genes: genes.presence || [:custom_prompt]
      },
      domain: domain_key.to_sym,
      tone: (story["tone"].presence || StoryEngine.infer_tone_offline(@project.prompt)).to_sym,
      seed: @project.seed,
      protagonist_bible: story["protagonist_bible"].presence || character["physical_description"].presence || @project.prompt,
      cargo_bible: story["cargo_bible"].presence || prop["description"]
    )
  end

  def set_user_and_account
    # Auto-seed inicial para que todo funcione sin login previo
    @current_account = Account.first_or_create!(name: "Showrunner Productions")
    @current_user = User.first_or_create!(name: "Enrique Director", email: "enrique@showrunner.ai")
  end

  def set_project
    @project = @current_user.projects.find(params[:id])
  end

  def project_params
    params.require(:project).permit(:prompt, :duration, :resolution, :dry_run, :token_budget)
  end
end
