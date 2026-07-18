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

  # NOTE: uses endless methods from 3, literal value omission from 3.1, Data.define from 3.2, Vernier profiling from 3.2.1
  spec.required_ruby_version = ">= 3.2.1"

  # spec.metadata["allowed_push_host"] = "TODO: Set to your gem server 'https://example.com'"
  # spec.metadata["rubygems_mfa_required"] = "true"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "https://github.com/teamshares/axn/blob/main/CHANGELOG.md"

  spec.metadata["rubygems_mfa_required"] = "true"

  # Ship the runtime payload only — allowlist, not denylist. A gem's shippable surface is small and
  # stable (lib/ + a few root docs), so enumerating it beats an ever-growing exclude list that
  # silently leaks new dev artifacts (docs site, editor config, tool configs) into the package.
  # `git ls-files` keeps this to tracked files. Anything not listed here (bin/, spec*, docs/,
  # internal-docs/, benchmark/, examples/, .cursor/, lefthook.yml, …) simply never ships.
  #
  # `.rubocop.yml` ships deliberately: internally-built downstream gems `inherit_gem: { axn:
  # ".rubocop.yml" }`. AGENTS-consuming.md / AGENTS-tool-adapters.md ship as consumer-facing guidance
  # the runtime references (`bundle show axn`).
  spec.files = IO.popen(
    %w[git ls-files -z --
       lib .rubocop.yml README.md CHANGELOG.md LICENSE.txt AGENTS-consuming.md AGENTS-tool-adapters.md],
    chdir: __dir__, err: IO::NULL,
  ) { |ls| ls.readlines("\x0", chomp: true) }
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Core dependencies
  spec.add_dependency "activemodel", ">= 7.2"    # For contract validation
  spec.add_dependency "activesupport", ">= 7.2"  # For compact_blank and friends
end
