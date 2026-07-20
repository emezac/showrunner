# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../lib/happy_horse_client"
require_relative "../../lib/qwen_router"

class HappyHorseClientTest < Minitest::Test
  class CapturingClient < HappyHorseClient
    attr_reader :payloads, :poll_count

    def initialize(failed_message: nil)
      config = HappyHorse::Config.new(
        api_key: "test-key",
        host: "example.test",
        video_model: "happyhorse-1.1",
        read_timeout: 1,
        open_timeout: 1
      )
      super(config: config, logger: HappyHorse::NullLogger.new)
      @payloads = []
      @poll_count = 0
      @failed_message = failed_message
    end

    def submit(payload)
      @payloads << payload
      HappyHorse::SubmitResult.new(task_id: "task-1", request_id: "request-1", raw: {})
    end

    def poll_until_done(_task_id, on_tick: nil)
      @poll_count += 1
      HappyHorse::PollResult.new(
        task_id: "task-1",
        status: @failed_message ? "FAILED" : "SUCCEEDED",
        video_url: @failed_message ? nil : "https://example.test/video.mp4",
        error_message: @failed_message,
        raw: {}
      )
    end
  end

  def test_normalizes_every_video_mode_to_provider_supported_duration
    client = CapturingClient.new

    client.submit_t2v(prompt: "one", duration: 7)
    client.submit_i2v(prompt: "two", first_frame_url: "https://example.test/frame.png", duration: 6)
    client.submit_r2v(prompt: "three", ref_image_url: "https://example.test/ref.png", duration: 2)

    assert_equal [5, 5, 3], client.payloads.map { |payload| payload.dig(:parameters, :duration) }
  end

  def test_duration_schema_failure_is_not_retried
    client = CapturingClient.new(failed_message: "duration must be in [3,4,5]")

    assert_raises(HappyHorse::TaskFailedError) do
      client.submit_with_retries(
        prompt: "action",
        mode: :i2v,
        first_frame_url: "https://example.test/frame.png",
        duration: 7,
        max_retries: 2
      )
    end

    assert_equal 1, client.poll_count
    assert_equal [5], client.payloads.map { |payload| payload.dig(:parameters, :duration) }
  end

  def test_transient_task_failure_retains_retry_policy
    client = Class.new(CapturingClient) do
      def poll_until_done(_task_id, on_tick: nil)
        @poll_count += 1
        status = @poll_count == 1 ? "FAILED" : "SUCCEEDED"
        HappyHorse::PollResult.new(
          task_id: "task-1",
          status: status,
          video_url: status == "SUCCEEDED" ? "https://example.test/video.mp4" : nil,
          error_message: status == "FAILED" ? "temporary provider failure" : nil,
          raw: {}
        )
      end
    end.new

    result = client.submit_with_retries(prompt: "action", mode: :t2v, duration: 5, max_retries: 2)

    assert result.succeeded?
    assert_equal 2, client.poll_count
    assert_equal 2, client.payloads.size
  end

  def test_narrative_images_forbid_reference_labels_but_diegetic_text_can_be_explicit
    client = CapturingClient.new

    exclusions = client.send(:narrative_image_exclusions, "The miniature hero rotates on the rod")
    explicit = client.send(:narrative_image_exclusions, "A title card reads The End")
    calibration = client.send(:narrative_image_exclusions, "ABSOLUTE MINIATURE SCALE CALIBRATION SHEET")

    assert_includes exclusions, "no unrequested visible text"
    assert_equal "", explicit
    assert_equal "", calibration
  end

  def test_expired_signed_image_references_are_not_reused
    client = CapturingClient.new
    now = Time.at(1_800_000_000)

    refute client.usable_reference_url?("https://oss.example.test/frame.png?Expires=1799999900&Signature=old", now: now)
    assert client.usable_reference_url?("https://oss.example.test/frame.png?Expires=1800003600&Signature=fresh", now: now)
    assert client.usable_reference_url?("https://example.test/permanent-frame.png", now: now)
    assert client.usable_reference_url?("data:image/png;base64,AAAA", now: now)
    refute client.usable_reference_url?("not a remote image", now: now)
  end

  def test_durable_local_reference_is_sent_as_data_uri_to_video_models
    public_url = "/generated/projects/999999/tests/reference.png"
    path = StableMedia.public_file_path(public_url)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, Base64.decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
    client = CapturingClient.new

    client.submit_i2v(prompt: "stable frame", first_frame_url: public_url, duration: 5)
    client.submit_r2v(prompt: "stable identity", ref_image_url: public_url, duration: 5)

    assert client.payloads[0].dig(:input, :img_url).start_with?("data:image/png;base64,")
    assert client.payloads[1].dig(:input, :media, 0, :url).start_with?("data:image/png;base64,")
  ensure
    FileUtils.rm_f(path) if path
  end

  def test_vision_content_resolves_durable_local_reference_without_network
    public_url = "/generated/projects/999999/tests/vision.png"
    path = StableMedia.public_file_path(public_url)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, Base64.decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))

    normalized = QwenRouter.normalize_vision_media([
      { type: "image_url", image_url: { url: public_url }, max_pixels: 256 }
    ])

    assert normalized.dig(0, :image_url, :url).start_with?("data:image/png;base64,")
  ensure
    FileUtils.rm_f(path) if path
  end
end
