# frozen_string_literal: true

require "open3"

# The files an adapter gem is documented to load directly must each require what their own CODE references.
# Nothing in the ordinary suite can catch a gap here: `spec_helper` loads all of axn, so a file that reaches a
# constant it never required still resolves it through some other file's require. The failure only appears in a
# process that loaded that one file — an adapter following the standalone-load path in
# `docs/recipes/authoring-tool-adapters.md` — and it appears at the FIRST CALL rather than at require time,
# because these are runtime references.
#
# So each case runs in a fresh Ruby that requires exactly one entry point and then exercises it.
RSpec.describe "standalone require completeness" do
  # The rendering path an adapter gem calls, loaded without the top-level `axn` entrypoint. `render` derives its
  # configs from the result, which reaches the schema builder and the canonicalization — neither of which this
  # file requires directly, and both of which it needs.
  def load_and_run(requires, body)
    script = <<~RUBY
      $LOAD_PATH.unshift("lib")
      #{Array(requires).map { |r| %(require "#{r}") }.join("\n")}
      #{body}
    RUBY
    out, status = Open3.capture2e(RbConfig.ruby, "-e", script, chdir: File.expand_path("../..", __dir__))
    [out, status]
  end

  describe "axn/extensions/serialization" do
    it "renders without the top-level entrypoint having been required first" do
      out, status = load_and_run(
        ["logger", "axn", "axn/extensions/serialization"],
        <<~RUBY,
          Axn.config.logger = Logger.new(IO::NULL)
          klass = Class.new do
            include Axn
            exposes :a, optional: true
            def call = expose(a: 1)
          end
          rendered = Axn::Extensions::Serialization.render(klass.call)
          # Asserted as data, never as `Hash#inspect` text — Ruby 3.4 changed that spacing.
          print [rendered.keys, rendered["a"]].inspect
        RUBY
      )

      expect(status).to be_success, "standalone load failed: #{out}"
      expect(out).to eq('[["a"], 1]')
    end
  end

  # Each entry point in isolation: requiring it alone must leave every constant its code calls resolvable.
  # A missing require here is what produced the NameError-on-first-render above, so the constants are asserted
  # directly rather than only through the one path that happens to reach them.
  {
    "axn/extensions/serialization" => %w[Axn::Reflection::Values Axn::Reflection::PropertyNames],
    "axn/reflection/property_names" => %w[Axn::Reflection::Values Axn::Reflection::Schema
                                          Axn::Reflection::SubfieldTree Axn::Internal::ShapeGraph],
    "axn/reflection/schema" => %w[Axn::Reflection::Values Axn::Reflection::SubfieldTree
                                  Axn::Internal::ShapeGraph],
    "axn/reflection/values" => %w[Axn::Internal::CycleGuard],
  }.each do |entry, constants|
    it "#{entry} resolves every constant its code calls" do
      out, status = load_and_run(entry, <<~RUBY)
        missing = #{constants.inspect}.reject do |name|
          Object.const_get(name)
        rescue NameError
          false
        end
        print missing.inspect
      RUBY

      expect(status).to be_success, "loading #{entry} alone failed: #{out}"
      expect(out).to eq("[]"), "#{entry} references but does not require: #{out}"
    end
  end
end
