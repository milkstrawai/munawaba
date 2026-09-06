require "test_helper"
require "tmpdir"
require_relative "../../lib/generators/munawaba/install_generator"

class InstallGeneratorTest < ActiveSupport::TestCase
  test "install is repeatable and touches only explicitly requested artifacts" do
    Dir.mktmpdir("munawaba-generator-") do |directory|
      FileUtils.mkdir_p(File.join(directory, "config"))
      route = "Rails.application.routes.draw {}"
      File.write(File.join(directory, "config/routes.rb"), route)
      capture_io { Munawaba::InstallGenerator.start([], destination_root: directory) }
      files = snapshot(directory)
      assert_equal 8, files.keys.grep(%r{db/migrate/}).size
      assert files.key?("config/initializers/munawaba.rb")
      assert_equal route, File.read(File.join(directory, "config/routes.rb"))
      assert_includes files.fetch("config/initializers/munawaba.rb"), "config.authenticate = ->(_controller) { false }"
      capture_io { Munawaba::InstallGenerator.start([], destination_root: directory) }
      assert_equal files, snapshot(directory)
      assert_empty(files.keys.grep(/credentials|recurring|schedule|routes/).reject { |name|
        name == "config/routes.rb" || name.start_with?("db/migrate/")
      })
    end
  end

  test "generator output is deterministic for a fixed migration clock and skips requested artifacts" do
    Dir.mktmpdir("munawaba-generator-") do |directory|
      first = File.join(directory, "first")
      second = File.join(directory, "second")
      travel_to(Time.utc(2026, 9, 5, 10)) do
        capture_io { Munawaba::InstallGenerator.start([], destination_root: first) }
        capture_io { Munawaba::InstallGenerator.start([], destination_root: second) }
      end
      assert_equal snapshot(first), snapshot(second)
      empty = File.join(directory, "empty")
      capture_io { Munawaba::InstallGenerator.start(%w[--no-migrations --no-initializer], destination_root: empty) }
      assert_empty snapshot(empty)
    end
  end

  private

  def snapshot(directory)
    Dir[File.join(directory, "**/*")].select { |path|
      File.file?(path)
    }.to_h { |path| [path.delete_prefix(directory + "/"), File.binread(path)] }
  end
end
