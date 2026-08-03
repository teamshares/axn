# frozen_string_literal: true

require "open3"

# Loads one axn file in a fresh Ruby and reports what that process can see: which axn files the load pulled in,
# and every constant those files' CODE references that does not resolve there.
#
# A module rather than helpers in the example group, because the whole point is the fresh process: the answers are
# memoized across examples (a dozen files, one Ruby each) and nothing here may run in the suite's own process,
# where all of axn is loaded and every reference resolves.
module StandaloneRequireProbe
  ROOT = File.expand_path("../..", __dir__)

  # The files an adapter gem is documented to load directly (`docs/recipes/authoring-tool-adapters.md`).
  ENTRY_POINTS = %w[
    axn/extensions/serialization
    axn/reflection/property_names
    axn/reflection/schema
    axn/reflection/values
  ].freeze

  # The derivation is required AFTER the subject, so nothing it pulls in can satisfy a reference on axn's behalf.
  PROGRAM = <<~RUBY.freeze
    $LOAD_PATH.unshift("lib")
    require ARGV.fetch(0)
    require "#{File.join(ROOT, 'spec/support/constant_references')}"

    $LOADED_FEATURES.grep(%r{\\A#{ROOT}/lib/axn/}).each do |path|
      file = path.delete_prefix("#{ROOT}/lib/")
      puts ["loaded", file].join("\\t")
      ConstantReferences.unresolved_in(path).each { |nesting, reference| puts ["gap", file, reference, nesting].join("\\t") }
    end
  RUBY

  @answers = {}

  # `[loaded_files, gaps]` for a process that required `file` and nothing else, each gap `[file, reference, nesting]`.
  def self.probe(file)
    @answers[file] ||= begin
      out, status = Open3.capture2e(RbConfig.ruby, "-e", PROGRAM, "--", file, chdir: ROOT)
      raise "loading #{file} alone failed: #{out}" unless status.success?

      rows = out.lines.map { |line| line.chomp.split("\t") }
      [rows.select { |kind,| kind == "loaded" }.map(&:last),
       rows.select { |kind,| kind == "gap" }.map { |_kind, *gap| gap }]
    end
  end

  # Every axn file an entry point's load pulls in, the entry points included — read from the loads themselves, so
  # a new require joins the set rather than needing to be listed.
  def self.loaded_files = ENTRY_POINTS.flat_map { |entry| probe(entry).first }.uniq

  def self.gaps_loaded_alone(file) = probe(file.delete_suffix(".rb")).last.select { |gap_file,| gap_file == file }

  def self.report(gaps) = gaps.map { |file, reference, nesting| "  #{file}: #{reference} (in #{nesting})" }.join("\n")
end

# The files an adapter gem is documented to load directly must each require what their own CODE references.
# Nothing in the ordinary suite can catch a gap here: `spec_helper` loads all of axn, so a file that reaches a
# constant it never required still resolves it through some other file's require. The failure only appears in a
# process that loaded that one file — an adapter following the standalone-load path in
# `docs/recipes/authoring-tool-adapters.md` — and it appears at the FIRST CALL rather than at require time,
# because these are runtime references.
#
# So each case runs in a fresh Ruby that requires exactly one entry point and then exercises it.
RSpec.describe "standalone require completeness" do
  # The references a standalone load legitimately cannot resolve, in two kinds — and neither is a missing require,
  # because the reverse require is either a CYCLE or a layer inversion:
  #
  #   - a lower file calling back into the layer that composes it. `PropertyNames` is the name renderer every
  #     message goes through, built on `Values`/`exceptions` (see AGENTS.md), and `Schema` composes
  #     `SubfieldTree`. Each such reference runs only from a message being built or a schema being walked, which
  #     the composing layer's own load has already made possible.
  #   - reflection reaching UP for something only a declared axn class has: `Validation::Base` supplies the
  #     validator entries a schema is derived from, `Core::Contract` records the file its generated readers are
  #     defined in, and `Internal::AsyncSerialization` renders an unserializable async argument. Reflecting over a
  #     class means the class exists, which means the library is loaded.
  #
  # This list may only SHRINK. Anything not on it is a missing require, and the last example fails if an entry
  # stops being unresolved, so a closed gap cannot linger here as a stale allowance.
  let(:upward_references) do
    [
      ["axn/exceptions.rb", "Axn::Internal::AsyncSerialization"],
      ["axn/exceptions.rb", "Axn::Reflection::PropertyNames"],
      ["axn/internal/shape_graph.rb", "Axn::Reflection::PropertyNames"],
      ["axn/reflection/schema.rb", "Axn::Core::Contract::GENERATED_READER_SOURCE_PATH"],
      ["axn/reflection/schema.rb", "Axn::Validation::Base"],
      ["axn/reflection/subfield_tree.rb", "Schema"],
    ]
  end

  def unexpected(gaps) = gaps.reject { |file, reference, _nesting| upward_references.include?([file, reference]) }

  # The rendering path an adapter gem calls, loaded without the top-level `axn` entrypoint. `render` derives its
  # configs from the result, which reaches the schema builder and the canonicalization — neither of which this
  # file requires directly, and both of which it needs.
  def load_and_run(requires, body)
    script = <<~RUBY
      $LOAD_PATH.unshift("lib")
      #{Array(requires).map { |r| %(require "#{r}") }.join("\n")}
      #{body}
    RUBY
    out, status = Open3.capture2e(RbConfig.ruby, "-e", script, chdir: StandaloneRequireProbe::ROOT)
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

  # Each entry point in isolation: requiring it alone must leave every constant resolvable that any axn file the
  # load pulled in REFERENCES — derived from each file's own parse tree (see spec/support/constant_references.rb)
  # rather than enumerated here.
  #
  # Enumerating them by hand is what let the defect this replaced survive: the list named four constants for a file
  # that had grown two more, so the first validated projection on the standalone path raised `NameError` while the
  # spec meant to pin that very contract stayed green. Deriving from the source found five more gaps, in two files
  # the hand-written list claimed to cover.
  #
  # Asserted over the whole LOADED SET, not just the entry file, because a gap in a file the entry point requires
  # breaks the entry point exactly as its own would (`axn/internal/shape_graph` reached `NativeMethods` that way).
  StandaloneRequireProbe::ENTRY_POINTS.each do |entry|
    it "#{entry} resolves every constant the code it loads references" do
      gaps = unexpected(StandaloneRequireProbe.probe(entry).last)

      expect(gaps).to be_empty,
                      "loading #{entry} alone leaves these referenced constants unresolved:\n" \
                      "#{StandaloneRequireProbe.report(gaps)}"
    end
  end

  # ...and the same file by file, which is stricter: a file may reference something only an entry point's OTHER
  # requires bring in, and is then broken for anyone loading it directly (that is how `subfield_tree`'s call back
  # into `Schema` surfaced). Every file an entry point loads is loaded alone here, the set read from the loads
  # themselves so a new require joins it.
  #
  # What neither example can pin is which FILE declared the require: resolvability is transitive, so a reference
  # satisfied by a dependency's own dependency reads as resolved — correctly, since nothing is broken until that
  # chain changes, at which point these examples fail. A file still declares the requires its own code needs (a
  # dependency is not a thing to inherit by luck), but what is asserted here is that the constant resolves.
  it "each file an entry point loads resolves its own references when nothing else is loaded" do
    gaps = StandaloneRequireProbe.loaded_files.flat_map { |file| unexpected(StandaloneRequireProbe.gaps_loaded_alone(file)) }

    expect(gaps).to be_empty,
                    "loaded alone, these files reference a constant nothing they require defines:\n" \
                    "#{StandaloneRequireProbe.report(gaps)}"
  end

  # The other direction: every allowance must still be a real one. Otherwise closing a gap leaves a permanent
  # exemption behind, and the next reference added to that file inherits it. It is also what keeps the derivation
  # honest — a check that resolved everything would pass every example above and fail this one.
  it "allows no upward reference that has since been closed" do
    unresolved = StandaloneRequireProbe.loaded_files
                                       .flat_map { |file| StandaloneRequireProbe.gaps_loaded_alone(file) }
                                       .map { |file, reference, _nesting| [file, reference] }.uniq

    expect(upward_references - unresolved).to be_empty
  end
end
