# frozen_string_literal: true

require "axn/testing/spec_helpers"

# Every Exception subclass reachable under Axn:: either includes Axn::Error — public, documented,
# rescuable, breaking to remove — or is deliberately excluded. The exclusions are pinned by name
# rather than by a namespace predicate, so adding one is a visible decision in this file.
RSpec.describe "Axn exception tagging" do
  # rubocop:disable Lint/ConstantDefinitionInBlock
  #
  # Axn::Failure is a control-flow signal from call!, not a fault: tagging it would make
  # `rescue Axn::Error` catch the intended outcome while still missing an unintended NoMethodError
  # from the action body. The other three are internal — EarlyCompletion is rescued before a Result
  # is returned and never escapes, and the two Registry bases are unreachable defaults now that no
  # public class descends from them.
  UNTAGGED = %w[
    Axn::Failure
    Axn::Internal::EarlyCompletion
    Axn::Internal::Registry::NotFound
    Axn::Internal::Registry::DuplicateError
  ].freeze
  # rubocop:enable Lint/ConstantDefinitionInBlock

  def self.exception_classes
    found = []
    walk = lambda do |mod, seen|
      mod.constants(false).each do |const|
        value = begin
          mod.const_get(const, false)
        rescue StandardError, ScriptError
          next
        end
        next unless value.is_a?(Module)
        next unless seen.add?(value.object_id)
        next unless value.name.to_s.start_with?("Axn")

        found << value if value.is_a?(Class) && value <= Exception
        walk.call(value, seen)
      end
    end
    walk.call(Axn, Set.new)
    found
  end

  let(:all_exceptions) { self.class.exception_classes }

  it "finds the exception classes at all (guards against a walk that silently matches nothing)" do
    expect(all_exceptions.size).to be >= 25
  end

  it "tags every exception class except the pinned exclusions" do
    untagged = all_exceptions.reject { |k| k.include?(Axn::Error) }.map { |k| k.name.to_s }.sort
    expect(untagged).to eq(UNTAGGED.sort)
  end

  it "keeps every pinned exclusion reachable, so a rename cannot leave a stale entry here" do
    missing = UNTAGGED.reject { |name| all_exceptions.any? { |k| k.name.to_s == name } }
    expect(missing).to be_empty, "pinned as untagged but no longer defined: #{missing.inspect}"
  end

  it "nests DuplicateFieldError with its ContractViolation siblings" do
    expect(Axn::ContractViolation.const_defined?(:DuplicateFieldError, false)).to be(true)
    expect(Axn.const_defined?(:DuplicateFieldError, false)).to be(false)
  end
end
