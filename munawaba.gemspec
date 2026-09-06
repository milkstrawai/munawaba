# frozen_string_literal: true

require_relative "lib/munawaba/version"

Gem::Specification.new do |spec|
  spec.name = "munawaba"
  spec.version = Munawaba::VERSION
  spec.authors = ["Ali Hamdi Ali Fadel"]
  spec.email = ["aliosm1997@gmail.com"]

  spec.summary = "On-call rotation administration inside your Rails application."
  spec.description = "Manage on-call rotations, preview handoffs, and reassign whole shifts " \
                     "inside an existing Rails application, with optional Slack notifications."
  spec.homepage = "https://github.com/milkstrawai/munawaba"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.glob("{app,config,db/migrate,lib,exe}/**/*", File::FNM_DOTMATCH)
                  .reject { |file| File.directory?(file) } +
               %w[CHANGELOG.md LICENSE.txt README.md SECURITY.md]
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |file| File.basename(file) }
  spec.require_paths = ["lib"]

  spec.add_dependency "actionpack", ">= 7.2", "< 8.2"
  spec.add_dependency "actionview", ">= 7.2", "< 8.2"
  spec.add_dependency "activejob", ">= 7.2", "< 8.2"
  spec.add_dependency "activerecord", ">= 7.2", "< 8.2"
  spec.add_dependency "pg", ">= 1.5", "< 2"
  spec.add_dependency "railties", ">= 7.2", "< 8.2"
  spec.add_dependency "tzinfo", "~> 2.0"
end
