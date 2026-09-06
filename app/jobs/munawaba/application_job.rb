# frozen_string_literal: true

module Munawaba
  class ApplicationJob < ActiveJob::Base
    queue_as { Munawaba.config.job_queue_name }
  end
end
