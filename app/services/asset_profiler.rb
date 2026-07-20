# frozen_string_literal: true

require_relative "source_profile_extractor"
require_relative "scale_contract_resolver"

class AssetProfiler
  PLACEHOLDER_CHARACTER_NAMES = %w[
    protagonist protagonista hero heroine héroe character personaje primary
  ].freeze

  class << self
    # Narrative references are provider inputs. They must never contain the
    # QA-only ruler/grid language used by calibration plates.
    def character_reference_prompt(character)
      data = character.to_h.with_indifferent_access
      prompt = data["visual_prompt"].to_s
      return prompt if prompt.present? && !technical_reference_prompt?(prompt)

      identity = data["source_identity_prompt"].presence || data["physical_description"].presence || data["name"]
      [
        "CANONICAL NARRATIVE CHARACTER REFERENCE — GENERATION SAFE",
        identity,
        data["scale_reference"],
        "single complete subject only, neutral full-body view, plain seamless background, even light",
        "preserve exact identity, proportions, materials, colors, wardrobe and distinctive marks",
        "no chart, ruler, grid, diagram, typography, labels, captions, logo or watermark"
      ].compact.join(". ")
    end

    def technical_reference_prompt?(prompt)
      prompt.to_s.match?(ScaleContractResolver::TECHNICAL_REFERENCE_PATTERN)
    end
  end

  # Repairs legacy/current profiles deterministically before regeneration.
  # Returns the canonical asset ids whose reference image is now stale.
  def self.repair_source_contract!(screenplay, project, assets, selection: nil)
    assets = (assets || {}).with_indifferent_access
    assets["characters"] ||= []
    changed = []

    Array(assets["characters"]).each_with_index do |raw, index|
      character = raw.with_indifferent_access
      name = character["name"].presence || "CHARACTER #{index + 1}"
      clean = SourceProfileExtractor.character_profile(project.prompt, name: name)
      next if clean.blank?

      before = [character["physical_description"], character["entity_type"], character["visual_prompt"], character["scale_reference"]].to_json
      canonical = canonical_character(screenplay, project, selection, name)
      character["physical_description"] = canonical["physical_description"]
      character["entity_type"] = canonical["entity_type"]
      character["wardrobe"] = canonical["wardrobe"] if character["wardrobe"].blank?
      character["visual_prompt"] = canonical["visual_prompt"]
      character["immutable_traits"] = (Array(character["immutable_traits"]) + Array(canonical["immutable_traits"])).uniq
      character["physical_constraints"] = (Array(character["physical_constraints"]) + Array(canonical["physical_constraints"])).uniq
      character["forbidden_mutations"] = (Array(character["forbidden_mutations"]) + Array(canonical["forbidden_mutations"])).uniq
      raw.replace(character.to_h) if raw.respond_to?(:replace)
      after = [character["physical_description"], character["entity_type"], character["visual_prompt"], character["scale_reference"]].to_json
      changed << (character["id"].presence || "char_#{index + 1}") if before != after
    end

    scale_result = ScaleContractResolver.apply!(assets, source_prompt: project.prompt)
    changed.concat(scale_result["changed_asset_ids"])
    assets["profiling_report"] = AssetFidelityEvaluator.evaluate(
      source_prompt: project.prompt,
      source_profiles: screenplay["source_profiles"],
      assets: assets
    ).merge("source_locked" => true, "scale_reconciled" => true)
    { "assets" => assets, "changed_asset_ids" => changed.uniq }
  end
  def self.profile_missing_props!(screenplay, project, assets, ledger: nil, config: QwenRouter::Config.default,
                                  cancellation_check: nil)
    cancellation_check&.call
    assets ||= {}
    assets["props"] ||= []
    return assets if assets["props"].present?

    system = <<~SYS
      You are a production continuity supervisor. Extract ONLY recurring or
      plot-relevant physical props/objects from the original prompt and
      screenplay. Do not classify characters, body parts or locations as
      props. For each prop lock its exact visible design, colors, materials,
      dimensions/relative scale and physical behavior. Return JSON:
      {
        "props": [{
          "name": string, "description": string, "color": string,
          "material": string, "dimensions": string,
          "distinctive_features": [string], "immutable_traits": [string],
          "physical_constraints": [string], "behavior_constraints": [string],
          "forbidden_mutations": [string], "scale_reference": string,
          "visual_prompt": string
        }],
        "world_rules": [string]
      }
    SYS
    user = JSON.generate(
      original_user_prompt: project.prompt,
      scenes: Array(screenplay["scenes"]).map do |scene|
        {
          heading: scene["heading"],
          action: scene["action"],
          shots: Array(scene["shots"]).map { |shot| shot["visual_prompt"] }
        }
      end
    )
    parsed, = QwenRouter.call_json(
      system: system,
      user: user,
      stage: :prop_profiling,
      max_tokens: 1_200,
      ledger: ledger,
      config: config
    )
    cancellation_check&.call
    return assets unless parsed.is_a?(Hash)

    client = HappyHorseClient.new
    Array(parsed["props"]).each_with_index do |raw_prop, index|
      cancellation_check&.call
      prop = raw_prop.with_indifferent_access
      image_url = nil
      begin
        result = client.submit_with_retries(
          prompt: prop["visual_prompt"] || "Neutral canonical reference of #{prop['name']}",
          mode: :t2i
        )
        image_url = result.image_url if result.succeeded?
      rescue ActiveRecord::RecordNotFound
        raise
      rescue StandardError => e
        Rails.logger.warn("Legacy prop reference generation failed: #{e.message}")
      ensure
        ledger[:video_credits_used] = (ledger[:video_credits_used] || 0) + 1 if ledger
      end

      assets["props"] << {
        "id" => "prop_#{index + 1}",
        "name" => prop["name"],
        "description" => prop["description"],
        "color" => prop["color"],
        "material" => prop["material"],
        "dimensions" => prop["dimensions"],
        "distinctive_features" => Array(prop["distinctive_features"]),
        "immutable_traits" => Array(prop["immutable_traits"]),
        "physical_constraints" => Array(prop["physical_constraints"]),
        "behavior_constraints" => Array(prop["behavior_constraints"]),
        "forbidden_mutations" => Array(prop["forbidden_mutations"]),
        "scale_reference" => prop["scale_reference"],
        "visual_prompt" => prop["visual_prompt"],
        "image_url" => image_url || "/placeholders/prop_#{index + 1}.png"
      }
    end
    assets["world_rules"] = (Array(assets["world_rules"]) + Array(parsed["world_rules"])).uniq
    assets
  rescue ActiveRecord::RecordNotFound
    raise
  rescue StandardError => e
    Rails.logger.warn("Missing prop profiling skipped: #{e.message}")
    assets
  end

  def self.profile!(screenplay, project, ledger: nil, config: nil, selection: nil, force_mock: false,
                    cancellation_check: nil)
    cancellation_check&.call
    # 1. Parse screenplay to extract list of characters and locations
    scenes = screenplay["scenes"] || []
    
    # Extract unique characters from dialogue lines
    raw_characters = scenes.flat_map { |s| (s["dialogue"] || []).map { |d| d["character"] } }.uniq.compact
    raw_characters = ["PROTAGONIST"] if raw_characters.empty?
    
    # Extract unique locations from scene headings
    # Typical heading format: "SCENE 1 - ASTEROID HANGAR (MYSTERY)"
    raw_locations = source_locations(scenes, screenplay["source_profiles"])

    assets = { "characters" => [], "props" => [], "locations" => [], "world_rules" => [] }

    # 2. Build assets list depending on dry_run
    if project.dry_run || force_mock
      # Deterministic offline mock generation
      raw_characters.each_with_index do |character_name, index|
        source_character = canonical_character(screenplay, project, selection, character_name)
        assets["characters"] << source_character.merge(
          "id" => "char_#{index + 1}", "image_url" => "/placeholders/character_#{index + 1}.png",
          "reference_images" => []
        )
      end

      raw_locations.each_with_index do |loc, idx|
        assets["locations"] << {
          "id" => "loc_#{idx + 1}",
          "name" => loc["name"],
          "description" => loc["description"],
          "lighting" => "Match only the lighting explicitly established by this scene.",
          "atmosphere" => "Match only the atmosphere explicitly established by this scene.",
          "visual_prompt" => canonical_location_prompt(loc),
          "image_url" => "/placeholders/location_#{idx + 1}.png"
        }
      end
      if (prop = canonical_prop(screenplay, project, selection))
        assets["props"] << prop.merge("id" => "prop_1", "image_url" => "/placeholders/prop_1.png")
      end
      assets["world_rules"] = [
        "preserve the same scale relationships in every shot",
        "respect gravity, contact, inertia and persistent attachments"
      ]
    else
      # Online mode using Qwen NLU
      system = <<~SYS
        You are a film profiling NLU agent. Given a screenplay structure and the user's original creative prompt, you must extract all mentioned characters and locations.

        CRITICAL PRIORITY:
        If the user's original creative prompt contains specific, detailed character descriptions (such as their physical appearance, clothing, body/material condition, face expressions, or paint conditions) or location details, you MUST prioritize and extract those exact details with maximum fidelity for the character/location profiles. Do not generate generic/different attributes if the user has provided specific ones.

        For each character, create:
          1. Detailed physical description (hair, clothing, approximate age, body condition).
          2. Personality traits.
          3. A unique physical habit or behavior.
          4. Entity type (human, creature, toy, robot, animal, etc.).
          5. Immutable identity traits that must never change between shots.
          6. Physical constraints, including articulated or attached body parts.
          7. A stable scale reference relative to the environment or another entity.
          8. A visual prompt for a neutral, full-body canonical reference image.
        For every recurring or plot-relevant prop/object, create:
          1. Exact description, color, material and dimensions/relative size.
          2. Distinctive visual features that uniquely identify it.
          3. Physical and behavior constraints (rigid, attached, rolls, cannot deform, etc.).
          4. Forbidden mutations that must never occur between shots.
          5. A neutral canonical reference-image prompt.
        For each location, create:
          1. Description of the spatial environment.
          2. Specific lighting cues (neon, dim contrast, volumetric, etc.).
          3. Atmosphere description.
          4. A visual prompt for generating the location background image.
        Scene, act, chapter and emotional-beat titles are NOT locations. Only
        extract a place when a slugline or scene action actually establishes it.
        Also infer world_rules: short, concrete physical or scale rules required by
        this particular story. Do not add genre assumptions that are absent from
        the source. If the story intentionally breaks a normal physical law,
        encode that exception explicitly and keep it stable.

        Return ONLY valid JSON with this exact schema:
        {
          "characters": [
            { "name": string, "entity_type": string, "physical_description": string, "wardrobe": string, "personality_traits": string, "unique_behavior": string, "immutable_traits": [string], "physical_constraints": [string], "forbidden_mutations": [string], "scale_reference": string, "visual_prompt": string }
          ],
          "props": [
            { "name": string, "description": string, "color": string, "material": string, "dimensions": string, "distinctive_features": [string], "immutable_traits": [string], "physical_constraints": [string], "behavior_constraints": [string], "forbidden_mutations": [string], "scale_reference": string, "visual_prompt": string }
          ],
          "locations": [
            { "name": string, "description": string, "lighting": string, "atmosphere": string, "immutable_traits": [string], "scale_reference": string, "visual_prompt": string }
          ],
          "world_rules": [string]
        }
      SYS

      user = JSON.generate({
        original_user_prompt: project.prompt,
        title: screenplay["title"],
        screenplay_scenes: scenes.map { |s| { heading: s["heading"], action: s["action"] } }
      })

      begin
        cancellation_check&.call
        parsed, _r = QwenRouter.call_json(
          system: system,
          user: user,
          stage: :assets_profiling,
          max_tokens: 2_800,
          ledger: ledger,
          config: config
        )
        cancellation_check&.call
        
        characters_list = []
        props_list = []
        locations_list = []
        world_rules = []

        if parsed.is_a?(Array)
          # Qwen returned a flat array of objects (could be characters, locations, or both)
          parsed.each do |item|
            next unless item.is_a?(Hash)
            item = item.with_indifferent_access
            
            # Heuristic to detect if it's a character or a location
            is_char = item[:physical_description].present? || item[:personality_traits].present? || item[:unique_behavior].present? || item[:visual_prompt].to_s.downcase.include?("portrait") || item[:visual_prompt].to_s.downcase.include?("character")
            is_prop = item[:material].present? || item[:dimensions].present? || item[:distinctive_features].present? || item[:behavior_constraints].present?
            is_loc = item[:lighting].present? || item[:atmosphere].present? || item[:visual_prompt].to_s.downcase.include?("environment") || item[:visual_prompt].to_s.downcase.include?("landscape") || item[:visual_prompt].to_s.downcase.include?("location")
            
            if is_char
              characters_list << item
            elsif is_prop
              props_list << item
            elsif is_loc
              locations_list << item
            else
              # Fallback: if it has 'name', default to character if name matches raw characters, else location
              if item[:name].present?
                if raw_characters.any? { |rc| item[:name].downcase.include?(rc.downcase) || rc.downcase.include?(item[:name].downcase) }
                  characters_list << item
                else
                  locations_list << item
                end
              end
            end
          end
        elsif parsed.is_a?(Hash)
          parsed = parsed.with_indifferent_access
          characters_list = parsed[:characters] || parsed[:Characters] || parsed[:character_profiles] || parsed[:character]
          props_list = parsed[:props] || parsed[:Props] || parsed[:objects] || parsed[:recurring_objects]
          locations_list = parsed[:locations] || parsed[:Locations] || parsed[:location_profiles] || parsed[:location]
          world_rules = parsed[:world_rules] || parsed[:physics_rules] || []
        end

        characters_list = Array(characters_list).compact
        props_list = Array(props_list).compact
        locations_list = Array(locations_list).compact
        assets["world_rules"] = Array(world_rules).compact.map(&:to_s)

        # A model may omit a profile or return a fluent but generic placeholder.
        # Repair it from preserved source material before any paid image call.
        if characters_list.empty?
          characters_list = raw_characters.map { |name| canonical_character(screenplay, project, selection, name) }
        else
          characters_list = characters_list.each_with_index.map do |profile, index|
            profile = profile.with_indifferent_access
            name = profile["name"].presence || raw_characters[index] || "CHARACTER #{index + 1}"
            source_character = canonical_character(screenplay, project, selection, name)
            AssetFidelityEvaluator.generic?(profile.to_h.values.join(" ")) ? source_character : merge_source_lock(profile, source_character)
          end
        end

        if props_list.empty? && (source_prop = canonical_prop(screenplay, project, selection))
          props_list << source_prop
        end

        if locations_list.empty? || locations_list.any? { |loc| AssetFidelityEvaluator.generic?(loc.to_h.values.join(" ")) }
          locations_list = raw_locations.map do |loc|
            {
              "name" => loc["name"], "description" => loc["description"],
              "lighting" => "Match the source scene exactly",
              "atmosphere" => "Match the source scene exactly",
              "visual_prompt" => canonical_location_prompt(loc)
            }
          end
        end

        preview = { "characters" => characters_list, "props" => props_list, "locations" => locations_list }
        ScaleContractResolver.apply!(preview, source_prompt: project.prompt)
        fidelity = AssetFidelityEvaluator.evaluate(
          source_prompt: project.prompt,
          source_profiles: screenplay["source_profiles"],
          assets: preview
        )
        unless fidelity["ready"]
          raise "Asset fidelity preflight rejected generation: #{fidelity['issues'].map { |i| i['code'] }.join(', ')}"
        end
        assets["profiling_report"] = fidelity.merge("source_locked" => true)

        # 3. Process extracted assets & generate base images via wan2.7-image-pro
        client = HappyHorseClient.new
        
        # Characters
        characters_list.each_with_index do |c, idx|
          cancellation_check&.call
          char_id = "char_#{idx + 1}"
          img_url = nil
          identity_url = nil
          calibration_url = nil
          
          # Generate base image T2I if budget and credentials allow
          begin
            cancellation_check&.call
            job_result = client.submit_with_retries(
              prompt: character_reference_prompt(c),
              mode: :t2i
            )
            img_url = job_result.image_url if job_result.succeeded?
          rescue ActiveRecord::RecordNotFound
            raise
          rescue => e
            Rails.logger.warn("Asset image generation failed: #{e.message}")
          end
          
          # Update budget tracking
          ledger[:video_credits_used] = (ledger[:video_credits_used] || 0) + 1 if ledger

          # Human faces benefit from a second close identity anchor. Miniatures
          # use that credit for a QA-only scale plate instead, never as a
          # narrative generation reference.
          if img_url.to_s.start_with?("http") && c["scale_class"] != "miniature_peer"
            begin
              cancellation_check&.call
              identity_result = client.submit_with_retries(
                prompt: "Canonical neutral identity close-up of the exact same #{c['name']}; preserve face, head shape, hair, skin/material, age and distinctive marks exactly; plain background, even light, no redesign; no text, labels, diagrams, captions or watermark",
                mode: :t2i,
                reference_image_urls: [img_url]
              )
              identity_url = identity_result.image_url if identity_result.succeeded?
            rescue ActiveRecord::RecordNotFound
              raise
            rescue => e
              Rails.logger.warn("Character identity close-up generation failed: #{e.message}")
            ensure
              ledger[:video_credits_used] = (ledger[:video_credits_used] || 0) + 1 if ledger
            end
          end

          if c["scale_calibration_prompt"].present?
            begin
              cancellation_check&.call
              calibration_result = client.submit_with_retries(
                prompt: c["scale_calibration_prompt"],
                mode: :t2i,
                reference_image_urls: [img_url].compact
              )
              calibration_url = calibration_result.image_url if calibration_result.succeeded?
            rescue ActiveRecord::RecordNotFound
              raise
            rescue => e
              Rails.logger.warn("Character scale calibration generation failed: #{e.message}")
            ensure
              ledger[:video_credits_used] = (ledger[:video_credits_used] || 0) + 1 if ledger
            end
          end

          assets["characters"] << {
            "id" => char_id,
            "name" => c["name"],
            "physical_description" => c["physical_description"],
            "personality_traits" => c["personality_traits"],
            "unique_behavior" => c["unique_behavior"],
            "entity_type" => c["entity_type"] || "character",
            "wardrobe" => c["wardrobe"],
            "immutable_traits" => Array(c["immutable_traits"]),
            "physical_constraints" => Array(c["physical_constraints"]),
            "forbidden_mutations" => Array(c["forbidden_mutations"]),
            "scale_reference" => c["scale_reference"],
            "scale_class" => c["scale_class"],
            "agency_mode" => c["agency_mode"],
            "allowed_attached_motion" => Array(c["allowed_attached_motion"]),
            "source_identity_prompt" => c["source_identity_prompt"],
            "visual_prompt" => c["visual_prompt"],
            "scale_calibration_prompt" => c["scale_calibration_prompt"],
            "image_url" => img_url || "/placeholders/character_#{idx + 1}.png",
            "reference_images" => [img_url, identity_url].compact,
            "qa_reference_images" => [calibration_url].compact,
            "scale_calibration_image_url" => calibration_url
          }
        end

        # Recurring props and story objects are first-class canonical assets.
        props_list.each_with_index do |prop, idx|
          cancellation_check&.call
          prop = prop.with_indifferent_access
          prop_id = "prop_#{idx + 1}"
          img_url = nil

          begin
            cancellation_check&.call
            job_result = client.submit_with_retries(
              prompt: prop["visual_prompt"] || "Neutral canonical product reference of #{prop['name']}",
              mode: :t2i
            )
            img_url = job_result.image_url if job_result.succeeded?
          rescue ActiveRecord::RecordNotFound
            raise
          rescue => e
            Rails.logger.warn("Prop asset image generation failed: #{e.message}")
          end

          ledger[:video_credits_used] = (ledger[:video_credits_used] || 0) + 1 if ledger
          assets["props"] << {
            "id" => prop_id,
            "name" => prop["name"],
            "description" => prop["description"],
            "color" => prop["color"],
            "material" => prop["material"],
            "dimensions" => prop["dimensions"],
            "distinctive_features" => Array(prop["distinctive_features"]),
            "immutable_traits" => Array(prop["immutable_traits"]),
            "physical_constraints" => Array(prop["physical_constraints"]),
            "behavior_constraints" => Array(prop["behavior_constraints"]),
            "forbidden_mutations" => Array(prop["forbidden_mutations"]),
            "scale_reference" => prop["scale_reference"],
            "visual_prompt" => prop["visual_prompt"],
            "image_url" => img_url || "/placeholders/prop_#{idx + 1}.png"
          }
        end

        # Locations
        locations_list.each_with_index do |l, idx|
          cancellation_check&.call
          loc_id = "loc_#{idx + 1}"
          img_url = nil
          
          begin
            cancellation_check&.call
            job_result = client.submit_with_retries(
              prompt: l["visual_prompt"] || "Cinematic landscape of #{l['name']}",
              mode: :t2i
            )
            img_url = job_result.image_url if job_result.succeeded?
          rescue ActiveRecord::RecordNotFound
            raise
          rescue => e
            Rails.logger.warn("Asset image generation failed: #{e.message}")
          end
          
          ledger[:video_credits_used] = (ledger[:video_credits_used] || 0) + 1 if ledger

          assets["locations"] << {
            "id" => loc_id,
            "name" => l["name"],
            "description" => l["description"],
            "lighting" => l["lighting"],
            "atmosphere" => l["atmosphere"],
            "visual_prompt" => l["visual_prompt"],
            "image_url" => img_url || "/placeholders/location_#{idx + 1}.png"
          }
        end
      rescue ActiveRecord::RecordNotFound
        raise
      rescue => e
        # Fallback to mock profiles on error
        Rails.logger.error("Failed to run Qwen Assets Profiling: #{e.message}. Falling back to mocks.")
        return profile!(
          screenplay, project, ledger: ledger, config: config, selection: selection,
          force_mock: true, cancellation_check: cancellation_check
        )
      end
    end

    ScaleContractResolver.apply!(assets, source_prompt: project.prompt)
    assets["profiling_report"] ||= AssetFidelityEvaluator.evaluate(
      source_prompt: project.prompt,
      source_profiles: screenplay["source_profiles"],
      assets: assets
    ).merge("source_locked" => true)
    assets
  end

  class << self
    private

    def canonical_character(screenplay, project, selection, name)
      source = source_profile_text(screenplay["source_profiles"], "characters")
      extracted = SourceProfileExtractor.character_profile(project.prompt, name: name)
      source = extracted if source.empty? || SourceProfileExtractor.profile_contaminated?(source)
      # A rich original prompt outranks an inferred story template. This is the
      # critical faithful-adaptation rule that prevents genre defaults from
      # replacing humans, toys, creatures or products described by the user.
      source = project.prompt.to_s.strip if source.empty? && project.prompt.to_s.strip.length >= 180
      source = selection.protagonist_bible.to_s.strip if source.empty? && selection&.respond_to?(:protagonist_bible)
      source = project.prompt.to_s.strip if source.empty?
      source = character_excerpt(source, name)[0, 4_000]
      entity_type = infer_entity_type(source)
      {
        "name" => name.presence || "PRIMARY CHARACTER",
        "entity_type" => entity_type,
        "physical_description" => source,
        "personality_traits" => "Preserve only behavior established by the screenplay.",
        "unique_behavior" => "Preserve source-defined movement and articulation.",
        "wardrobe" => "Exactly as described in the canonical source; no substitutions.",
        "immutable_traits" => ["same identity", "same materials and colors", "same body proportions", "same distinctive marks"],
        "physical_constraints" => physical_constraints_for(entity_type),
        "forbidden_mutations" => ["different entity type", "unrelated actor", "different face or head", "different materials", "different colors", "different proportions"],
        "scale_reference" => "Lock the exact source-defined scale relative to recurring objects and environment",
        "visual_prompt" => "CANONICAL SOURCE-LOCKED full-body reference of #{name}: #{source}. Exact entity type, anatomy/articulation, materials, colors, wardrobe, proportions and damage marks. Neutral pose, plain background, even light, entire body visible. No redesign or substitutions."
      }
    end

    def canonical_prop(screenplay, project, selection)
      descriptor = selection.cargo_bible.to_s.strip if selection&.respond_to?(:cargo_bible)
      return if descriptor.blank? || descriptor.match?(/\A(?:the )?(?:mysterious )?(?:focus )?(?:object|cargo)\z/i)

      story = [project.prompt, screenplay.to_json].join(" ").downcase
      terms = descriptor.downcase.scan(/[\p{L}\p{N}]+/).select { |word| word.length >= 4 }
      return unless terms.any? { |word| story.include?(word) }

      physics, behavior = prop_physics(descriptor)
      {
        # Keep source nouns in the canonical name so deterministic shot/entity
        # binding can recognize the object without relying on an LLM again.
        "name" => descriptor.split(/[.;\n]/).first.to_s.squish[0, 100],
        "description" => descriptor,
        "color" => "Exactly as specified by the source",
        "material" => "Exactly as specified by the source",
        "dimensions" => "Lock source-defined size and relative scale",
        "distinctive_features" => [descriptor],
        "immutable_traits" => [descriptor, "same color", "same material", "same size"],
        "physical_constraints" => physics,
        "behavior_constraints" => behavior,
        "forbidden_mutations" => ["different color", "different material", "different size", "deformation", "duplication"],
        "scale_reference" => "Preserve exact size relative to the primary character",
        "visual_prompt" => "CANONICAL SOURCE-LOCKED neutral object reference: #{descriptor}. Exact colors, material, dimensions, markings and geometry; isolated, plain background, no redesign."
      }
    end

    def source_locations(scenes, profiles = nil)
      candidates = Array(scenes).each_with_index.map do |scene, index|
        heading = scene["heading"].to_s.strip
        action = [scene["action"], *Array(scene["shots"]).map { |shot| shot["source_visual_prompt"] || shot["visual_prompt"] }]
          .compact.join(" ").squish[0, 1_200]
        slugline = heading.match?(/\A(?:INT\.?|EXT\.?|INT\.?\s*\/\s*EXT\.?)\b/i) || heading.match?(/\s+-\s+(?:DAY|NIGHT|DAWN|DUSK|DÍA|NOCHE|AMANECER|ATARDECER)\z/i)
        name = slugline ? heading.sub(/\A(?:INT\.?|EXT\.?|INT\.?\s*\/\s*EXT\.?)\s*/i, "").sub(/\s+-\s+(?:DAY|NIGHT|DAWN|DUSK|DÍA|NOCHE|AMANECER|ATARDECER)\z/i, "").titleize : "Scene #{index + 1} environment"
        { "name" => name, "description" => action.presence || heading, "explicit" => slugline }
      end
      explicit = candidates.select { |item| item["explicit"] }
      return explicit.uniq { |item| item["name"] }.each { |item| item.delete("explicit") } if explicit.any?

      # Narrative section titles are beats, not places. With no sluglines, use
      # one source-grounded environment instead of inventing one per heading.
      location_profile = source_profile_text(profiles, "locations")
      [{
        "name" => "Primary story environment",
        "description" => (location_profile.presence || candidates.map { |item| item["description"] }.join(" ")).squish[0, 2_000]
      }]
    end

    def source_profile_text(profiles, kind)
      return profiles.to_s.strip unless profiles.is_a?(Hash)

      (profiles[kind] || profiles[kind.to_sym] || profiles["all"] || profiles[:all]).to_s.strip
    end

    def canonical_location_prompt(location)
      "CANONICAL SOURCE-LOCKED empty environment reference for #{location['name']}: #{location['description']}. Preserve architecture, spatial layout, scale, time of day, lighting and atmosphere exactly; no characters, no invented genre elements."
    end

    def merge_source_lock(model_profile, source_profile)
      model = model_profile.respond_to?(:to_h) ? model_profile.to_h.stringify_keys : {}
      source_profile.merge(
        "name" => model["name"].presence || source_profile["name"],
        "personality_traits" => model["personality_traits"].presence || source_profile["personality_traits"],
        "unique_behavior" => model["unique_behavior"].presence || source_profile["unique_behavior"]
      )
    end

    def infer_entity_type(text)
      value = text.to_s.downcase
      return "toy_or_figurine" if value.match?(/foosball|futbol[ií]n|figurine|figure|toy|juguete|muñec|plastic player/)
      return "robot" if value.match?(/robot|android|androide|mech/)
      return "animal" if value.match?(/animal|dog|cat|horse|perro|gato|caballo/)
      return "creature" if value.match?(/creature|monster|alien|criatura|monstruo/)
      return "human" if value.match?(/human|person|woman|man|girl|boy|mujer|hombre|persona|niña|niño/)

      "character"
    end

    def character_excerpt(source, name)
      value = source.to_s
      key = name.to_s.downcase.strip
      return value if key.empty? || PLACEHOLDER_CHARACTER_NAMES.include?(key)

      sections = value.split(/\n{2,}|(?=^\#{1,4}\s+)/)
      matches = sections.select { |section| section.downcase.include?(key) }.join("\n")
      matches.length >= 80 ? matches : value
    end

    def physical_constraints_for(entity_type)
      if entity_type == "human"
        ["anatomically plausible motion", "persistent face, body and wardrobe"]
      else
        ["preserve source-defined articulation and attachments", "rigid parts remain rigid", "no human anatomy substitution"]
      end
    end

    def prop_physics(descriptor)
      text = descriptor.to_s.downcase
      common = ["persistent identity, geometry, material, color and scale"]
      behavior = ["respect gravity, contact, inertia, collisions and declared attachments"]

      if text.match?(/ball|sphere|orb|pelota|bal[oó]n|esfera/)
        common.concat(["rigid shape", "does not deform or change diameter"])
        behavior.concat(["moves only after visible contact or declared force", "continuous physically plausible rolling or ballistic trajectory"])
      elsif text.match?(/liquid|fluid|water|oil|l[ií]quido|agua|aceite/)
        common << "conserve volume and material"
        behavior << "flows continuously under gravity and container contact"
      elsif text.match?(/cloth|fabric|cape|flag|tela|capa|bandera/)
        common << "flexible material with persistent weave, cut and attachments"
        behavior << "deformation follows contact, gravity and airflow without topology changes"
      elsif text.match?(/attached|mounted|bolted|tied|pegado|unido|atornillado|amarrado/)
        common << "declared attachment remains fixed"
      else
        common << "preserve source-defined rigidity or flexibility"
      end
      [common, behavior]
    end
  end
end
