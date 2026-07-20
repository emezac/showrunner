# frozen_string_literal: true

require "digest"
require "fileutils"
require "ipaddr"
require "net/http"
require "resolv"
require "tempfile"
require "uri"
require "stable_media"

# Downloads every generated canonical image while its signed provider URL is
# valid. The durable, byte-identical copy becomes the source of truth for UI, QA,
# regeneration and video references after the provider URL expires.
class CanonicalMediaStore
  MAX_DOWNLOAD_BYTES = 20 * 1024 * 1024
  MAX_REDIRECTS = 3

  class << self
    def materialize_manifest!(project)
      manifest = (project.manifest || {}).deep_dup.with_indifferent_access
      changed = materialize_assets!(project.id, manifest["assets"] || {})
      changed = materialize_screenplay!(project.id, manifest["screenplay"] || {}) || changed
      project.update!(manifest: manifest) if changed
      manifest
    end

    def materialize_assets!(project_id, assets)
      changed = false
      %w[characters props locations].each do |type|
        Array(assets[type]).each_with_index do |asset, index|
          key = asset["id"].presence || "#{type.singularize}_#{index + 1}"
          changed = materialize_field!(asset, "image_url", "stable_image_url", project_id, type, key) || changed
          changed = materialize_array!(asset, "reference_images", "stable_reference_images", project_id, type, "#{key}_reference") || changed
          changed = materialize_array!(asset, "qa_reference_images", "stable_qa_reference_images", project_id, type, "#{key}_qa") || changed
          changed = materialize_field!(
            asset, "scale_calibration_image_url", "stable_scale_calibration_image_url",
            project_id, type, "#{key}_scale"
          ) || changed
        end
      end
      changed
    end

    def materialize_screenplay!(project_id, screenplay)
      changed = false
      Array(screenplay["scenes"]).each_with_index do |scene, scene_index|
        plate = scene["continuity_plate"].to_h
        if plate.present?
          changed = materialize_field!(
            plate, "image_url", "stable_image_url", project_id, "continuity_plates", "scene_#{scene_index + 1}"
          ) || changed
          scene["continuity_plate"] = plate
        end

        Array(scene["shots"]).each_with_index do |shot, shot_index|
          key = shot["id"].presence || "scene_#{scene_index + 1}_shot_#{shot_index + 1}"
          changed = materialize_field!(shot, "image_url", "stable_image_url", project_id, "storyboard", key) || changed
          continuity = shot["continuity"].to_h
          if continuity.present?
            changed = materialize_array!(
              continuity, "reference_image_urls", "stable_reference_image_urls",
              project_id, "shot_references", key
            ) || changed
            changed = materialize_field!(
              continuity, "continuity_plate_url", "stable_continuity_plate_url",
              project_id, "continuity_plates", "#{key}_plate"
            ) || changed
            shot["continuity"] = continuity
          end
        end
      end
      changed
    end

    def prefer_stable_for_display!(manifest)
      assets = manifest["assets"].to_h
      %w[characters props locations].each do |type|
        Array(assets[type]).each do |asset|
          asset["image_url"] = asset["stable_image_url"] if StableMedia.local_available?(asset["stable_image_url"])
          stable_refs = Array(asset["stable_reference_images"]).select { |url| StableMedia.local_available?(url) }
          asset["reference_images"] = stable_refs if stable_refs.any?
          stable_qa = Array(asset["stable_qa_reference_images"]).select { |url| StableMedia.local_available?(url) }
          asset["qa_reference_images"] = stable_qa if stable_qa.any?
          if StableMedia.local_available?(asset["stable_scale_calibration_image_url"])
            asset["scale_calibration_image_url"] = asset["stable_scale_calibration_image_url"]
          end
        end
      end
      Array(manifest.dig("screenplay", "scenes")).each do |scene|
        plate = scene["continuity_plate"].to_h
        plate["image_url"] = plate["stable_image_url"] if StableMedia.local_available?(plate["stable_image_url"])
        scene["continuity_plate"] = plate if plate.present?
        Array(scene["shots"]).each do |shot|
          shot["image_url"] = shot["stable_image_url"] if StableMedia.local_available?(shot["stable_image_url"])
          continuity = shot["continuity"].to_h
          stable_refs = Array(continuity["stable_reference_image_urls"]).select { |url| StableMedia.local_available?(url) }
          continuity["reference_image_urls"] = stable_refs if stable_refs.any?
          if StableMedia.local_available?(continuity["stable_continuity_plate_url"])
            continuity["continuity_plate_url"] = continuity["stable_continuity_plate_url"]
          end
          shot["continuity"] = continuity if continuity.present?
        end
      end
      manifest
    end

    def capture(project_id:, url:, kind:, key:)
      return url if StableMedia.local_available?(url)
      return unless StableMedia.usable_remote?(url)

      uri = URI.parse(url.to_s)
      return if uri.host.to_s.end_with?(".test")

      bytes, content_type = download(uri)
      raise "provider response is not an image" unless content_type.to_s.start_with?("image/")

      digest = Digest::SHA256.hexdigest(bytes)
      extension = verified_extension(bytes, content_type)
      relative_dir = File.join("generated", "projects", project_id.to_i.to_s, "media")
      output_dir = Rails.root.join("public", relative_dir)
      FileUtils.mkdir_p(output_dir)
      filename = "#{digest}#{extension}"
      output_path = output_dir.join(filename)
      persist_exact_copy(bytes, output_path) unless File.file?(output_path)
      "/#{File.join(relative_dir, filename)}"
    rescue StandardError => e
      Rails.logger.warn("[CanonicalMediaStore] Could not persist #{kind}/#{key}: #{e.class}: #{e.message}")
      nil
    end

    private

    def materialize_field!(record, source_key, stable_key, project_id, kind, key)
      return false if content_addressed?(record[stable_key])

      stable = capture(project_id: project_id, url: record[source_key], kind: kind, key: key)
      return false unless stable

      record[stable_key] = stable
      true
    end

    def materialize_array!(record, source_key, stable_key, project_id, kind, key)
      current = Array(record[stable_key]).select { |url| content_addressed?(url) }
      sources = Array(record[source_key])
      return false if sources.empty? || current.size >= sources.size

      stable = sources.each_with_index.filter_map do |url, index|
        capture(project_id: project_id, url: url, kind: kind, key: "#{key}_#{index + 1}")
      end
      return false if stable.empty? || stable == Array(record[stable_key])

      record[stable_key] = stable
      true
    end

    def content_addressed?(url)
      StableMedia.local_available?(url) && url.to_s.match?(%r{/generated/projects/\d+/media/[a-f0-9]{64}\.(?:png|jpg|webp)\z})
    end

    def download(uri, redirects = MAX_REDIRECTS)
      raise "too many redirects" if redirects.negative?
      raise "unsupported media URL" unless %w[http https].include?(uri.scheme)
      validate_public_host!(uri.host)

      response = Net::HTTP.start(
        uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 10, read_timeout: 30
      ) { |http| http.request(Net::HTTP::Get.new(uri.request_uri)) }
      if response.is_a?(Net::HTTPRedirection)
        return download(URI.join(uri.to_s, response["location"]), redirects - 1)
      end
      raise "download failed with HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
      raise "image exceeds #{MAX_DOWNLOAD_BYTES} bytes" if response.body.to_s.bytesize > MAX_DOWNLOAD_BYTES

      [response.body, response["content-type"].to_s.split(";").first]
    end

    def validate_public_host!(host)
      addresses = Resolv.getaddresses(host.to_s)
      raise "media host could not be resolved" if addresses.empty?

      private_address = addresses.any? do |address|
        ip = IPAddr.new(address)
        ip.loopback? || ip.link_local? || ip.private?
      end
      raise "private or local media hosts are not allowed" if private_address
    rescue IPAddr::InvalidAddressError
      raise "invalid media host"
    end

    def persist_exact_copy(bytes, output_path)
      Tempfile.create(["showrunner_reference", File.extname(output_path)]) do |file|
        file.binmode
        file.write(bytes)
        file.flush
        file.fsync
        FileUtils.mv(file.path, output_path)
      end
    end

    def verified_extension(bytes, content_type)
      return ".png" if bytes.start_with?("\x89PNG\r\n\x1A\n".b)
      return ".jpg" if bytes.start_with?("\xFF\xD8\xFF".b)
      return ".webp" if bytes.start_with?("RIFF".b) && bytes.byteslice(8, 4) == "WEBP".b

      raise "unsupported or invalid image payload (#{content_type})"
    end

    def sanitize(value)
      value.to_s.downcase.gsub(/[^a-z0-9_-]+/, "_").gsub(/\A_+|_+\z/, "").presence || "media"
    end
  end
end
