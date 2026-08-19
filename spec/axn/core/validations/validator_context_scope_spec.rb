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

  describe "inside a validator's option bag" do
    it "is refused on a top-level expects, naming the field, the validator and the fix" do
      expect do
        Class.new do
          include Axn
          expects :v, type: { klass: String, on: :create }
          def call = nil
        end
      end.to raise_error(ArgumentError, /`on:` inside type: on \["v"\].*validation context.*no context.*if:.*unless:/m)
    end

    it "is refused on an exposes" do
      expect do
        Class.new do
          include Axn
          exposes :v, type: { klass: String, on: :create }
          def call = expose(v: "x")
        end
      end.to raise_error(ArgumentError, /`on:` inside type:/)
    end

    it "is refused on an on: subfield, whose own on: is the parent and stays legal" do
      expect do
        Class.new do
          include Axn
          expects :parent, type: Hash
          expects :zip, on: :parent, type: { klass: String, on: :create }
          def call = nil
        end
      end.to raise_error(ArgumentError, /`on:` inside type: on \["zip"\]/)
    end

    it "is refused on a block-form shape member" do
      expect do
        Class.new do
          include Axn
          expects(:h, type: Hash) { field :x, type: { klass: String, on: :create } }
          def call = nil
        end
      end.to raise_error(ArgumentError, /`on:` inside type:/)
    end

    it "is refused through Axn::Factory.build" do
      expect do
        Axn::Factory.build(expects: { v: { type: { klass: String, on: :create } } }) { nil }
      end.to raise_error(ArgumentError, /`on:` inside type:/)
    end

    # AM installs the context gate on the KEY's presence whatever the value, and `Array(nil) & anything` is
    # empty — so every spelling names a context no call is in, and none is "the default context".
    [:create, nil, false, []].each do |spelling|
      it "is refused for on: #{spelling.inspect}" do
        expect do
          Class.new do
            include Axn
            expects :v, type: { klass: String, on: spelling }
            def call = nil
          end
        end.to raise_error(ArgumentError, /`on:` inside type:/)
      end
    end

    # Axn's own validators are validator ENTRIES too, and none of the five reads `:on` for anything of its
    # own — so the check covers them without rejecting anything legitimate.
    {
      length: { minimum: 5, on: :create },
      presence: { on: :create },
      inclusion: { in: %w[a b], on: :create },
      numericality: { greater_than: 1, on: :create },
      format: { with: /\Aa+\z/, on: :create },
      of: { klass: String, on: :create },
      validate: { with: ->(_v) {}, on: :create },
    }.each do |key, entry|
      it "is refused on #{key}:" do
        opts = key == :of ? { type: Array, key => entry } : { optional: true, key => entry }
        # `of:` is named as the BAG rather than as the validator key, and is the one row here that no longer
        # reaches the entry scan at all: an `of:` bag can also sit one rung down, or on either map axis, where
        # the entry scan cannot see it — so it is checked as a bag (`_reject_inner_contract_context_scope!`,
        # which runs during canonicalization, ahead of the scan) and one message covers every position
        # (PRO-3166). The scan's own coverage rests on the other six rows, which is where it belongs: the scan
        # is generic over entries and has no `of:`-specific branch.
        inside = key == :of ? "an `of:` bag" : "#{key}:"
        expect do
          klass = Class.new do
            include Axn
            def call = nil
          end
          klass.expects :v, **opts
        end.to raise_error(ArgumentError, /`on:` inside #{Regexp.escape(inside)}/)
      end
    end

    # The row above covers the ARRAY spelling of an `of:` bag. Both spellings are answered by the bag check
    # now, in one wording — the map bag used to reach the entry scan and read `on:` inside of: on ["v"] while
    # its array twin read `on:` inside an `of:` bag, which is one defect described two ways.
    it "is refused on a map's of: bag, in the same words the array spelling uses" do
      expect do
        Class.new do
          include Axn
          expects :v, type: Hash, of: { values: Integer, on: :create }
          def call = nil
        end
      end.to raise_error(ArgumentError, /\A`on:` inside an `of:` bag on :v names an ActiveModel validation context/)
    end

    # A raw `shape:` bag is itself a validator entry, so it is caught here — and the check sits ahead of
    # `_derive_raw_shape_container!`, which rebuilds the node and would otherwise drop the key being reported.
    it "is refused on a raw shape: bag's own on:" do
      expect do
        Class.new do
          include Axn
          expects :h, type: Hash, shape: { members: [], container: Hash, on: :create }
          def call = nil
        end
      end.to raise_error(ArgumentError, /`on:` inside shape:/)
    end

    it "names every offending entry, not only the first" do
      expect do
        klass = Class.new do
          include Axn
          def call = nil
        end
        klass.expects :v, type: { klass: String, on: :create }, length: { minimum: 2, on: :create }
      end.to raise_error(ArgumentError, /type:.*length:|length:.*type:/)
    end

    it "is refused on a raw shape: member, which bypasses expects' option handling" do
      member = Axn::Core::Contract::ShapeConfig.new(field: :x, validations: { type: { klass: String, on: :create } })

      expect do
        Class.new do
          include Axn
          expects :h, type: Hash, shape: { members: [member], container: Hash }
          def call = nil
        end
      end.to raise_error(ArgumentError, /shape member `x`.*`on:` inside type:|`on:` inside type:.*shape member `x`/m)
    end

    it "is refused on an object-backed member, which only the declaration walk sees" do
      member = Class.new do
        def field = :x
        def validations = { type: { klass: String, on: :create } }
      end.new

      expect do
        Class.new do
          include Axn
          expects :h, type: Hash, shape: { members: [member], container: Hash }
          def call = nil
        end
      end.to raise_error(ArgumentError, /`on:` inside type:/)
    end
  end

  # Over-rejection is the failure mode when a guard is tightened, so these pin what must keep being ACCEPTED.
  # Audit them by INVERSE mutation: make the guard test any gate key rather than `:on` alone, and confirm one
  # of these fails. Dropping its `validator_entries` filter is NOT a live mutation — no route leaves a
  # bag-level `:on` in a bag this guard reads (on a field it is `expects`' own kwarg; on a member it is
  # refused earlier), so the filter is a statement of remit rather than a load-bearing test.
  describe "what stays legal" do
    it "accepts a declaration-level on: — the subfield parent" do
      klass = Class.new do
        include Axn
        expects :parent, type: Hash
        expects :zip, on: :parent, type: String
        def call = nil
      end

      expect(klass.call(parent: { zip: "02118" })).to be_ok
    end

    it "accepts a declaration-level on: beside a legitimately gated entry" do
      klass = Class.new do
        include Axn
        expects :parent, type: Hash
        expects :flag, type: :boolean
        expects :zip, on: :parent, type: { klass: String, if: :flag }
        def call = nil
      end

      expect(klass.call(parent: { zip: "02118" }, flag: true)).to be_ok
      expect(klass.call(parent: { zip: 5 }, flag: false)).to be_ok # the gate is closed, so the type check is skipped
    end

    it "accepts on: :ambient_context" do
      klass = Class.new do
        include Axn
        expects :who, on: :ambient_context, type: String, optional: true
        def call = nil
      end

      expect(klass.call).to be_ok
    end

    it "accepts every other ActiveModel shared option nested in an entry" do
      klass = Class.new do
        include Axn
        expects :v, optional: true, length: { minimum: 5, if: :never, unless: :never, allow_nil: true, allow_blank: true }
        def call = nil
        def never = false
      end

      expect(klass.call(v: "a")).to be_ok
    end

    it "accepts a nested strict:, which raises rather than being inert" do
      klass = Class.new do
        include Axn
        expects :v, optional: true, length: { minimum: 5, strict: true }
        def call = nil
      end

      expect(klass.call(v: "a")).not_to be_ok
    end
  end

  # A member's bag reaches `validates` as-is on the raw route, so a bag-level `on:` silences every validator in
  # it; on the block route the same key is absorbed as the subfield-parent kwarg and then dropped. One reason
  # covers both, and it is not the reader-option or unknown-key reason.
  describe "at the top of a shape member's bag" do
    it "is refused on a raw shape: member" do
      member = Axn::Core::Contract::ShapeConfig.new(field: :x, validations: { presence: true, on: :create })

      expect do
        Class.new do
          include Axn
          expects :h, type: Hash, shape: { members: [member], container: Hash }
          def call = nil
        end
      end.to raise_error(ArgumentError, /shape member `x` does not support on:.*validation context.*no subfield parent/m)
    end

    it "is refused on a block-form member" do
      expect do
        Class.new do
          include Axn
          expects(:h, type: Hash) { field :x, presence: true, on: :create }
          def call = nil
        end
      end.to raise_error(ArgumentError, /shape member `x` does not support on:/)
    end

    it "keeps reporting an unknown key as unknown rather than as a context option" do
      expect do
        Class.new do
          include Axn
          expects(:h, type: Hash) { field :x, tpye: String }
          def call = nil
        end
      end.to raise_error(ArgumentError, /Unknown key\(s\) :tpye/)
    end

    it "keeps reporting a reader option with the reader-less reason" do
      expect do
        Class.new do
          include Axn
          expects(:h, type: Hash) { field :x, type: String, as: :y }
          def call = nil
        end
      end.to raise_error(ArgumentError, /does not support as:.*reader-less/m)
    end

    it "still accepts the tolerance a member's bag may legitimately carry" do
      member = Axn::Core::Contract::ShapeConfig.new(field: :x, validations: { type: String, allow_nil: true })
      klass = Class.new do
        include Axn
        expects :h, type: Hash, shape: { members: [member], container: Hash }
        def call = nil
      end

      expect(klass.call(h: { x: nil })).to be_ok
    end
  end

  describe "at the top of an exposes declaration" do
    it "is refused, naming both meanings it cannot have" do
      expect do
        Class.new do
          include Axn
          exposes :v, presence: true, on: :create
          def call = expose(v: "x")
        end
      end.to raise_error(ArgumentError, /exposes does not support `on:` on \["v"\].*no subfield parent.*no ActiveModel validation contexts/m)
    end

    it "is refused whatever the value, since nothing reads it either way" do
      expect do
        Class.new do
          include Axn
          exposes :v, presence: true, on: nil
          def call = expose(v: "x")
        end
      end.to raise_error(ArgumentError, /exposes does not support `on:`/)
    end

    it "leaves an ordinary exposes untouched" do
      klass = Class.new do
        include Axn
        exposes :v, type: String
        def call = expose(v: "x")
      end

      expect(klass.call).to be_ok
    end

    # Two checks stand between a gem and this spelling; this example covers the inner one. Registering `:on`
    # as field metadata is refused outright (Extensions::Config#register_field_metadata_key), so the registry
    # is planted directly here to reach the guard behind it. `_partition_field_options` routes a key by that
    # registry, so a claimed `:on` arrives in the metadata bag rather than the validations one — the guard
    # reads both, because what `on:` means on an exposure is not a loaded extension's to decide.
    it "is refused even where :on has been planted in the field-metadata registry" do
      Axn::Extensions.config.registered_field_metadata_keys.add(:on)

      expect do
        Class.new do
          include Axn
          exposes :v, presence: true, on: :create
          def call = expose(v: "x")
        end
      end.to raise_error(ArgumentError, /exposes does not support `on:`/)
    ensure
      Axn::Extensions.config.registered_field_metadata_keys.delete(:on)
    end

    it "cannot be reached that way in the first place — registering :on is refused" do
      expect { Axn::Extensions.config.register_field_metadata_key(:on) }
        .to raise_error(ArgumentError, /Cannot register :on as field metadata/)
      expect(Axn::Extensions.config.registered_field_metadata_keys).not_to include(:on)
    end
  end
end
