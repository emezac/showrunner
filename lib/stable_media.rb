# frozen_string_literal: true

require "base64"
require "uri"

# Resolves short-lived provider URLs and durable project-owned image copies.
# Durable copies live below public/generated/projects and are converted to a
# compact data URI only at the provider boundary; base64 is never persisted in
# the database.
module StableMedia
  PUBLIC_PREFIX = "/generated/projects/"
  MAX_DATA_BYTES = 20 * 1024 * 1024

  module_function

  def reference?(value)
    data_uri?(value) || usable_remote?(value) || local_available?(value)
  end

  def provider_input(value)
    candidate = value.to_s
    return candidate if data_uri?(candidate) || usable_remote?(candidate)
    return data_uri(candidate) if local_available?(candidate)

    nil
  end

  def usable_remote?(value, now: Time.now)
    url = value.to_s
    return false unless url.start_with?("http://", "https://")

    uri = URI.parse(url)
    expires = URI.decode_www_form(uri.query.to_s).to_h.values_at("Expires", "expires").compact.first
    expires.nil? || expires.to_i > now.to_i + 60
  rescue URI::InvalidURIError, ArgumentError
    false
  end

  def local_available?(value)
    path = public_file_path(value)
    path && File.file?(path) && File.size(path).positive?
  rescue SystemCallError
    false
  end

  def public_file_path(value)
    url = value.to_s
    return unless url.start_with?(PUBLIC_PREFIX)

    root = defined?(Rails) ? Rails.root.join("public").to_s : File.expand_path("../public", __dir__)
    expanded = File.expand_path(url.delete_prefix("/"), root)
    generated_root = File.expand_path("generated/projects", root)
    return unless expanded.start_with?("#{generated_root}/")

    expanded
  end

  def data_uri(value)
    path = public_file_path(value)
    return unless path && File.file?(path)
    raise ArgumentError, "stable reference is too large" if File.size(path) > MAX_DATA_BYTES

    mime = case File.extname(path).downcase
           when ".jpg", ".jpeg" then "image/jpeg"
           when ".webp" then "image/webp"
           when ".gif" then "image/gif"
           else "image/png"
           end
    "data:#{mime};base64,#{Base64.strict_encode64(File.binread(path))}"
  end

  def data_uri?(value)
    value.to_s.start_with?("data:image/")
  end
end
