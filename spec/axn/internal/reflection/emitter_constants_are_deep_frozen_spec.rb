# frozen_string_literal: true

# A constant the emitter writes into a schema is SHARED, and a schema is handed to a consumer that may do
# anything with it. Schemas are rebuilt per call, so a consumer is entitled to treat the Hash it receives as
# its own — but a mutable `[]`/`{}` reached from a constant is the same object in every schema the process
# emits, and mutating it through one action's document silently rewrites every later one. Measured twice, in
# the same file, two thousand lines apart: appending through one action's blank WITNESS changed a DIFFERENT
# action class's `enum` to `[[99]]`, and appending through one action's blank FLOOR changed another's to
# `["", [:x], {}, false, nil]`.
#
# The second was found by review after the first had been fixed, because that fix enumerated the sites it
# knew about (`BLANK_BRANCH_WITNESS`, and a spec naming its two members) while a third constant with the
# identical shape sat earlier in the same file. So this DERIVES the rule instead: every container constant in
# the emitter is deep-frozen, whether or not today's code happens to emit it. That is stricter than the hazard
# strictly needs — a lookup table nothing emits is held to it too — and deliberately so, because "does this
# one reach a document?" is exactly the question the hand-enumerated fix got wrong, and freezing a table that
# never leaves the gem costs nothing.
#
# The tolerated set is EMPTY, and the point is that it stays that way: an exclusion list here would hide the
# next constant the way the last one was hidden.
module EmitterConstants
  LIB = File.expand_path("../../../../lib/axn/internal/reflection", __dir__)

  class << self
    # Names come from the SOURCE rather than off the modules, because `Module#constants` omits private
    # constants and `BLANK_BRANCH_WITNESS` — one of the two that actually leaked — is private. `NAME = ` at an
    # indented line is how every constant in this namespace is written.
    def harvested_names
      Dir[File.join(LIB, "**", "*.rb")]
        .flat_map { |f| File.readlines(f).filter_map { |line| line[/^\s+([A-Z][A-Z0-9_]+) =/, 1] } }
        .uniq.map(&:to_sym)
    end

    def modules(root = Axn::Internal::Reflection, seen = {}.compare_by_identity)
      return [] if seen.key?(root)

      seen[root] = true
      nested = root.constants(false).flat_map do |name|
        value = resolve_public(root, name)
        value.is_a?(Module) && value.name.to_s.start_with?("Axn::Internal::Reflection") ? modules(value, seen) : []
      end
      [root, *nested]
    end

    # Every container constant, as [label, value]. Looked up per module because one name can be defined in
    # more than one of them. A harvested name is resolved with `const_defined?` plus a lexical `module_eval`,
    # the one read that reaches a private constant from outside.
    def containers
      modules.flat_map do |mod|
        harvested_names.filter_map do |name|
          next unless mod.const_defined?(name, false)

          value = resolve_lexical(mod, name)
          next unless value.is_a?(Array) || value.is_a?(Hash)

          ["#{mod}::#{name}", value]
        end
      end
    end

    # Every Array, Hash and String reachable from `value`, named by the path it sits at, so a failure points
    # at the member rather than only the constant. Cycle-guarded by IDENTITY: a frozen `[]` and another frozen
    # `[]` are `eql?` but are not the same leak.
    def unfrozen_within(value, path, seen = {}.compare_by_identity)
      return [] if seen.key?(value)

      seen[value] = true
      case value
      when Array
        (value.frozen? ? [] : ["#{path} (Array)"]) +
          value.each_with_index.flat_map { |member, i| unfrozen_within(member, "#{path}[#{i}]", seen) }
      when Hash
        (value.frozen? ? [] : ["#{path} (Hash)"]) +
          value.flat_map { |k, v| unfrozen_within(v, "#{path}[#{k.inspect}]", seen) }
      when String
        value.frozen? ? [] : ["#{path} (String)"]
      else
        []
      end
    end

    private

    def resolve_public(mod, name)
      mod.const_get(name, false)
    rescue StandardError
      nil
    end

    def resolve_lexical(mod, name)
      mod.module_eval(name.to_s)
    rescue StandardError
      nil
    end
  end
end

RSpec.describe "every container constant the emitter holds" do
  # Both controls exist because a harvest that silently matched nothing, or a resolver blind to the private
  # constants, would pass the real example vacuously.
  it "harvests names from source, including the private ones a module never lists" do
    expect(EmitterConstants.harvested_names).to include(:BLANK_BRANCH_WITNESS, :BLANK_WIRE_VALUES)
    expect(Axn::Internal::Reflection::Schema.constants(false)).not_to include(:BLANK_BRANCH_WITNESS)
  end

  it "resolves enough of them to be measuring something" do
    expect(EmitterConstants.modules.size).to be >= 10
    expect(EmitterConstants.containers.map(&:first)).to include(
      "Axn::Internal::Reflection::Schema::BLANK_BRANCH_WITNESS",
      "Axn::Internal::Reflection::Schema::Vocabulary::BLANK_WIRE_VALUES",
    )
  end

  it "is deep-frozen, every member and every member's members" do
    offenders = EmitterConstants.containers.flat_map { |label, value| EmitterConstants.unfrozen_within(value, label) }

    expect(offenders).to be_empty
  end
end
