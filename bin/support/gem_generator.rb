# frozen_string_literal: true

require "fileutils"

# Dev-only scaffolder for downstream axn-consuming gems (PRO-2949). Shells out to `bundle gem NAME`
# for the generic baseline, then lays axn core's canonical delta on top so a fresh gem starts
# conformant instead of being reverse-engineered from an existing one. Lives under bin/ and is
# excluded from the packaged gem (the gemspec rejects bin/ from spec.files).
class GemGenerator
  class Error < StandardError; end

  TEMPLATES_DIR = File.expand_path("../templates", __dir__)
  CORE_ROOT = File.expand_path("../..", __dir__)

  # Lower bound for the axn runtime dependency. First version to ship the DSL surface (Configurable,
  # tool registry) downstream gems build on; the temporary Gemfile main pin tracks ahead of it.
  AXN_LOWER_BOUND = ">= 0.1.0-alpha.4.3"

  # bundle gem output the base layer deliberately drops. (bin/setup is replaced, not dropped.)
  CRUFT = %w[bin/console].freeze

  # Rails testing topology:
  #   :dual — non-Rails spec/ + a spec_rails/dummy_app Rails suite (default; mirrors axn core)
  #   :only — Rails-only; all specs live in spec_rails/dummy_app, no non-Rails spec/
  #   :none — pure Ruby; no dummy app
  RAILS_MODES = %i[dual only none].freeze

  RAKEFILE_TEMPLATES = { none: "Rakefile.tmpl", dual: "Rakefile_dual.tmpl", only: "Rakefile_rails_only.tmpl" }.freeze
  CI_TEMPLATES = { none: "ci.yml.tmpl", dual: "ci_dual.yml.tmpl", only: "ci_rails_only.yml.tmpl" }.freeze

  def initialize(name, dest_parent: Dir.pwd, install: true, output: $stdout, input: $stdin, summary: nil, rails: :dual)
    @name = name
    @dest_parent = dest_parent
    @install = install
    @out = output
    @in = input
    @provided_summary = summary
    @rails = rails
  end

  def run
    validate!
    bundle_gem!
    overlay!
    install! if @install
    say "Scaffolded #{@name} at #{gem_dir}"
    gem_dir
  end

  private

  attr_reader :name

  def gem_dir = @gem_dir ||= File.join(@dest_parent, name)

  def hyphenated? = name.include?("-")

  def rails? = @rails != :none

  def rails_only? = @rails == :only

  def validate!
    raise Error, "gem name is required" if name.to_s.strip.empty?
    # Each hyphen-delimited segment must start with a letter, so every generated module segment is a
    # valid Ruby constant. `axn-1foo` would otherwise scaffold `module 1foo` / `:1foo` — syntax errors.
    unless name.match?(/\A[a-z][a-z0-9_]*(-[a-z][a-z0-9_]*)*\z/)
      raise Error, "invalid gem name #{name.inspect} (each '-'-separated segment must start with a letter; use a-z, 0-9, _)"
    end
    raise Error, "invalid rails mode #{@rails.inspect} (one of #{RAILS_MODES.inspect})" unless RAILS_MODES.include?(@rails)
    raise Error, "#{gem_dir} already exists" if File.exist?(gem_dir)
  end

  def bundle_gem!
    shell!(["bundle", "gem", name, "--test=rspec", "--linter=rubocop", "--ci=github", "--mit", "--no-coc", "--changelog"],
           chdir: @dest_parent, quiet: true)
    raise Error, "bundle gem did not create #{gem_dir}" unless File.directory?(gem_dir)

    normalize_git_branch
  end

  # bundle gem inits the repo on the machine's git default branch (often master), but the generated
  # CI only listens on main — so a push to master would get no CI. Rename to main. Best-effort:
  # a git hiccup here shouldn't sink an otherwise-good scaffold.
  def normalize_git_branch
    shell!(%w[git branch -M main], chdir: gem_dir, quiet: true)
  rescue Error
    say "WARNING: could not rename the generated repo's branch to main; rename it manually so CI runs."
  end

  def install!
    shell!(%w[bundle install], chdir: gem_dir)
    shell!(%w[bundle install], chdir: File.join(gem_dir, "spec_rails", "dummy_app")) if rails?
  rescue Error => e
    say "WARNING: #{e.message}. Run `bundle install` manually in #{gem_dir}."
  end

  # Shell out to a bundler subcommand outside our own bundle context (with_unbundled_env), so the
  # child sees the new gem's environment rather than axn's BUNDLE_GEMFILE.
  def shell!(cmd, chdir:, quiet: false)
    run = lambda do
      opts = { chdir: }
      opts[:out] = File::NULL if quiet
      raise Error, "command failed: #{cmd.join(' ')}" unless system(*cmd, **opts)
    end
    defined?(Bundler) ? Bundler.with_unbundled_env(&run) : run.call
  end

  def overlay!
    delete_cruft
    write_static_files
    write_rakefile
    write_ci
    write_gemspec
    write_gemfile
    write_entry_files
    write_rubocop
    write_docs
    configure_specs
    write_dummy_app if rails?
  end

  def delete_cruft
    CRUFT.each { |f| FileUtils.rm_f(File.join(gem_dir, f)) }
    FileUtils.rm_rf(File.join(gem_dir, "sig"))
    FileUtils.rm_f(File.join(gem_dir, ".github", "workflows", "main.yml"))
  end

  def write_static_files
    refresh = File.join(gem_dir, "bin", "refresh")
    FileUtils.cp(File.join(CORE_ROOT, "bin", "refresh"), refresh)
    File.chmod(0o755, refresh)

    write("bin/setup", render("setup.tmpl"))
    File.chmod(0o755, File.join(gem_dir, "bin", "setup"))

    write(".gitignore", render("gitignore.tmpl"))
    write(".tool-versions", render("tool_versions.tmpl"))
    write("CHANGELOG.md", render("changelog.md.tmpl"))
    write(".github/CODEOWNERS", render("codeowners.tmpl"))
    write(".github/renovate.json5", render("renovate.json5.tmpl"))
  end

  def write_rakefile = write("Rakefile", render(RAKEFILE_TEMPLATES.fetch(@rails)))

  def write_ci = write(".github/workflows/ci.yml", render(CI_TEMPLATES.fetch(@rails)))

  def write_gemspec
    write("#{name}.gemspec", render("gemspec.tmpl",
                                    gem_name: name,
                                    version_const:,
                                    version_require:,
                                    homepage:,
                                    summary_ruby: summary.dump,
                                    axn_lower: AXN_LOWER_BOUND))
  end

  def write_gemfile
    write("Gemfile", render("Gemfile.tmpl", gem_name: name))
  end

  def configure_specs
    if rails_only?
      # Rails-only: all specs live in the dummy app; drop the root Rails-free suite and its .rspec.
      FileUtils.rm_rf(File.join(gem_dir, "spec"))
      FileUtils.rm_f(File.join(gem_dir, ".rspec"))
      return
    end

    write(".rspec", render("rspec.tmpl"))
    write("spec/spec_helper.rb", render("spec_helper.rb.tmpl", gem_name: name))
    spec_file = Dir[File.join(gem_dir, "spec", "**", "*_spec.rb")].first
    write(relative(spec_file), render("entry_spec.rb.tmpl", module: module_const)) if spec_file
  end

  # A minimal, bootable Rails dummy app (ActiveRecord + sqlite) with its own bundle. Its specs run
  # via the `spec_rails` rake task (`cd spec_rails/dummy_app && BUNDLE_GEMFILE=Gemfile rspec`).
  def write_dummy_app
    base = "spec_rails/dummy_app"
    write("#{base}/config/boot.rb", render("dummy/boot.rb.tmpl"))
    write("#{base}/config/application.rb", render("dummy/application.rb.tmpl"))
    write("#{base}/config/environment.rb", render("dummy/environment.rb.tmpl"))
    write("#{base}/config/database.yml", render("dummy/database.yml.tmpl"))
    write("#{base}/config/routes.rb", render("dummy/routes.rb.tmpl"))
    write("#{base}/config/storage.yml", render("dummy/storage.yml.tmpl"))
    write("#{base}/Rakefile", render("dummy/Rakefile.tmpl"))
    write("#{base}/Gemfile", render("dummy/Gemfile.tmpl", gem_name: name))
    write("#{base}/.rspec", render("dummy/rspec.tmpl"))
    write("#{base}/.gitignore", render("dummy/gitignore.tmpl"))
    write("#{base}/spec/spec_helper.rb", render("dummy/spec_helper.rb.tmpl"))
    write("#{base}/spec/integration_spec.rb", render("dummy/integration_spec.rb.tmpl", module: module_const))
  end

  def write_entry_files
    write(entry_rel, entry_content)
    write("lib/#{name}.rb", shim_content) if hyphenated?
  end

  def write_rubocop
    content = render("rubocop.yml.tmpl")
    content += render("rubocop_filename_exclude.tmpl", shim: "lib/#{name}.rb") if hyphenated?
    write(".rubocop.yml", content)
  end

  def write_docs
    write("README.md", render("readme.md.tmpl", gem_name: name, summary:))
    write("AGENTS.md", render("agents.md.tmpl", gem_name: name))
    claude = File.join(gem_dir, "CLAUDE.md")
    FileUtils.rm_f(claude)
    File.symlink("AGENTS.md", claude)
  end

  # --- derivations (reuse bundle gem's own name/nesting decisions) --------------------------------

  # bundle gem writes lib/**/version.rb with the module nesting it chose (incl. acronym casing).
  # Reuse it as the source of truth rather than re-deriving and risking drift.
  def version_file
    @version_file ||= Dir[File.join(gem_dir, "lib", "**", "version.rb")].first ||
                      raise(Error, "could not find generated version.rb")
  end

  def module_names = @module_names ||= File.read(version_file).scan(/^\s*module\s+(\w+)/).flatten

  def module_const = module_names.join("::")

  def version_const = "#{module_const}::VERSION"

  # e.g. "lib/axn/foo/version" or "lib/foo_bar/version"
  def version_require = relative(version_file).sub(/\.rb\z/, "")

  # The real (nested) entry sits beside the version dir: "lib/axn/foo.rb" / "lib/foo_bar.rb".
  def entry_rel = "#{File.dirname(version_require)}.rb"

  # Config namespace key: strip a leading axn- and normalize (axn-ruby_llm -> :ruby_llm).
  def namespace_key = name.sub(/\Aaxn-/, "").tr("-", "_")

  def homepage = "https://github.com/teamshares/#{name}"

  # The one field worth capturing at creation time. Precedence: explicit summary: arg > interactive
  # tty prompt > a gem-name-aware fallback stub. Fills both gemspec (summary + description) and the
  # README description line.
  def summary = @summary ||= @provided_summary || prompt_summary || "#{name}: an axn-consuming gem."

  # Prompt only when input is an interactive terminal, so the spec and any non-interactive/CI run
  # (piped or --no-install) fall through to the stub instead of blocking on gets.
  def prompt_summary
    return nil unless @in.respond_to?(:tty?) && @in.tty?

    @out.print "One-line summary for #{name} (blank to fill in later): "
    line = @in.gets&.strip
    line unless line.nil? || line.empty?
  end

  def relative(path) = path.sub("#{gem_dir}/", "")

  def entry_content
    version_relative = "#{File.basename(entry_rel, '.rb')}/version"
    indent = "  " * module_names.length

    lines = [
      "# frozen_string_literal: true",
      "",
      'require "axn"',
      'require "active_support/deprecation"',
      "",
      %(require_relative "#{version_relative}"),
      "",
    ]
    module_names.each_with_index { |mod, i| lines << (("  " * i) + "module #{mod}") }
    entry_body.each_line { |line| lines << (line.strip.empty? ? "" : indent + line.rstrip) }
    (module_names.length - 1).downto(0) { |i| lines << ("#{'  ' * i}end") }
    "#{lines.join("\n")}\n"
  end

  def entry_body
    <<~RUBY.chomp
      extend Axn::Configurable

      # Per-gem config namespace (Axn::Configurable, PRO-2880). Set globally with
      # `#{module_const}.configure { |c| c.enabled = false }`; read via `#{module_const}.config.enabled`
      # (and the generated `enabled?` predicate). The namespace keeps these settings from colliding
      # with another adapter's `configure(:...)` bag on the same action.
      config_namespace :#{namespace_key}

      # Starter setting — replace with your gem's own. Add `overridable: true` to let a consuming Axn
      # set it per-class via `configure(:#{namespace_key}) { |c| c.enabled = false }` (read back with
      # `#{module_const}.resolve_override_for(axn_class, :enabled)`); `callable: true` for a lambda default.
      setting :enabled, default: true

      class Error < StandardError; end

      # A dedicated deprecator instance, so a consuming Rails app can register it
      # (Rails.application.deprecators[:#{namespace_key}] = #{module_const}.deprecator) and govern
      # its behavior (silence in test, raise in CI, etc.).
      def self.deprecator
        @deprecator ||= ActiveSupport::Deprecation.new("1.0", "#{name}")
      end
    RUBY
  end

  def shim_content
    <<~RUBY
      # frozen_string_literal: true

      require_relative "#{entry_rel.sub(%r{\Alib/}, '').sub(/\.rb\z/, '')}"
    RUBY
  end

  # --- template + file helpers -------------------------------------------------------------------

  def render(template_name, **vars)
    content = File.read(File.join(TEMPLATES_DIR, template_name))
    vars.each { |key, value| content = content.gsub("__#{key.to_s.upcase}__") { value.to_s } }
    content
  end

  def write(relative_path, content)
    path = File.join(gem_dir, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def say(message) = @out.puts(message)
end
