# frozen_string_literal: true

module Munawaba
  class Engine < ::Rails::Engine
    isolate_namespace Munawaba
    engine_name "munawaba_engine"

    initializer "munawaba.filter_secrets" do |app|
      app.config.filter_parameters += [:slack_webhook_url]
    end

    config.after_initialize do
      Munawaba.configuration.validate!
    end
  end
end
