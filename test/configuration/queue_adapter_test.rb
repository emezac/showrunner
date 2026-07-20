# frozen_string_literal: true

require "test_helper"

class QueueAdapterTest < ActiveSupport::TestCase
  test "test environment never dispatches production jobs to sidekiq" do
    assert_instance_of ActiveJob::QueueAdapters::TestAdapter, ActiveJob::Base.queue_adapter
  end
end
