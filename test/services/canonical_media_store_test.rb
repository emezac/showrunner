# frozen_string_literal: true

require "test_helper"

class CanonicalMediaStoreTest < ActiveSupport::TestCase
  PNG = Base64.decode64(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
  )

  test "materializes and prefers a content-addressed durable reference" do
    project_id = 999_998
    digest = Digest::SHA256.hexdigest(PNG)
    public_url = "/generated/projects/#{project_id}/media/#{digest}.png"
    path = StableMedia.public_file_path(public_url)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, PNG)
    assets = {
      "characters" => [{
        "id" => "char_1", "image_url" => public_url,
        "reference_images" => [public_url]
      }],
      "props" => [], "locations" => []
    }

    assert CanonicalMediaStore.materialize_assets!(project_id, assets)
    character = assets.dig("characters", 0)
    assert_equal public_url, character["stable_image_url"]
    assert_equal [public_url], character["stable_reference_images"]
    assert StableMedia.provider_input(public_url).start_with?("data:image/png;base64,")

    manifest = { "assets" => assets, "screenplay" => { "scenes" => [] } }.with_indifferent_access
    display_character = manifest.dig("assets", "characters", 0)
    display_character["image_url"] = "https://expired.example/image.png?Expires=1"
    CanonicalMediaStore.prefer_stable_for_display!(manifest)
    assert_equal public_url, display_character["image_url"]
  ensure
    FileUtils.rm_f(path) if path
  end
end
