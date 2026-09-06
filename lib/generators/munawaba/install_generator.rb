# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module Munawaba
  class InstallGenerator < Rails::Generators::Base
    include Rails::Generators::Migration

    source_root File.expand_path("templates", __dir__)
    class_option :migrations, type: :boolean, default: true, desc: "Copy Munawaba's migrations"
    class_option :initializer, type: :boolean, default: true, desc: "Copy Munawaba's initializer"

    def self.next_migration_number(dirname)
      ActiveRecord::Generators::Base.next_migration_number(dirname)
    end

    def install
      template "munawaba.rb", "config/initializers/munawaba.rb" if options[:initializer]
      if options[:migrations]
        Dir[Munawaba::Engine.root.join("db/migrate/*.rb")].each do |path|
          basename = File.basename(path).sub(/\A\d+_/, "")
          next if Dir[File.join(destination_root, "db/migrate/*_#{basename}")].any?

          migration_template path, "db/migrate/#{basename}"
        end
      end
      say "Configure access in config/initializers/munawaba.rb."
      say 'Add to config/routes.rb: mount Munawaba::Engine => "/on-call"'
      say "Run bin/rails db:migrate, then schedule the background jobs:"
      say "https://github.com/milkstrawai/munawaba#background-jobs"
    end
  end
end
