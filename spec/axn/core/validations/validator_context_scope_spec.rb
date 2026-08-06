# frozen_string_literal: true

require "axn/testing/spec_helpers"

# Axn has no ActiveModel validation contexts: `Validation::Fields` calls `valid?` with no context, while
# `validate` installs a gate of `!(Array(options[:on]) & Array(validation_context)).empty?` whenever
# `options.key?(:on)` — an intersection that is empty on every call. So an `on:` anywhere ActiveModel reads
# validator options names a check that runs on no call, and is refused at declaration.
#
# A DECLARATION-level `on:` on `expects` is a different option entirely — axn's subfield parent — and every
# control here exists to keep it working.
RSpec.describe "an `on:` that names a validation context" do
  # A Hash subclass that denies its own class. ActiveModel classifies with `case`/`when`, which is C-level and
  # ignores this, so a bag like it still reaches the validator carrying `on:` and still goes inert — the guard
  # has to agree, or it is one a caller can switch off.
  let(:disowning_hash) do
    Class.new(Hash) do
      def is_a?(klass) = klass == Hash ? false : super
      def key?(_key) = false
    end
  end

  describe "Validation::Base.entry_context_scoped?" do
    it "reads a plain bag carrying on:" do
      expect(Axn::Validation::Base.entry_context_scoped?({ klass: String, on: :create })).to be(true)
    end

    it "reads a bag without on: as unscoped" do
      expect(Axn::Validation::Base.entry_context_scoped?({ klass: String, if: :flag })).to be(false)
    end

    it "reads a non-Hash entry as unscoped" do
      expect(Axn::Validation::Base.entry_context_scoped?(String)).to be(false)
      expect(Axn::Validation::Base.entry_context_scoped?(true)).to be(false)
      expect(Axn::Validation::Base.entry_context_scoped?(nil)).to be(false)
    end

    it "is not fooled by a bag that denies being a Hash and hides its keys" do
      bag = disowning_hash.new
      bag[:on] = :create

      expect(bag.is_a?(Hash)).to be(false) # the lie
      expect(Axn::Validation::Base.normalize_validator_options(bag)).to have_key(:on) # what AM still sees
      expect(Axn::Validation::Base.entry_context_scoped?(bag)).to be(true)
    end
  end
end
