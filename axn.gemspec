# frozen_string_literal: true

require_relative "lib/axn/version"

Gem::Specification.new do |spec|
  spec.name = "axn"
  spec.version = Axn::VERSION
  spec.authors = ["Kali Donovan"]
  spec.email = ["kali@teamshares.com"]

  spec.summary = "A terse convention for business logic"
  spec.description = "Pattern for writing callable service objects with contract validation and exception handling"
  spec.homepage = "https://github.com/teamshares/axn"
  spec.license = "MIT"

  # NOTE: uses endless methods from 3, literal value omission from 3.1, Data.define from 3.2
  spec.required_ruby_version = ">= 3.2.0"

  # spec.metadata["allowed_push_host"] = "TODO: Set to your gem server 'https://example.com'"
  # spec.metadata["rubygems_mfa_required"] = "true"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "https://github.com/teamshares/axn/blob/main/CHANGELOG.md"

  spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (File.expand_path(f) == __FILE__) ||
        f.start_with?(*%w[
                        bin/ test/ spec/ spec_rubocop/ spec_rails/ features/ examples/
                        .git .github appveyor Gemfile Gemfile.lock yarn.lock .rspec_status pkg/
                        node_modules/ tmp/ .rspec .rubocop .tool-versions package.json
                      ])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Core dependencies
  spec.add_dependency "activemodel", "> 7.0"    # For contract validation
  spec.add_dependency "activesupport", "> 7.0"  # For compact_blank and friends
end
