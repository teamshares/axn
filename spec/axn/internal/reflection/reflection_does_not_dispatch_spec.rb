# frozen_string_literal: true

# Reflection may run NONE of a caller's code, and a declared `type:`/`of:`/`model:` token is the caller's own
# Class. This spec DERIVES the check rather than enumerating sites: it instruments a token with every method a
# classification or a rendering might reach, walks each declaration position, and asserts what got dispatched.
# A new site added anywhere in the emitter shows up here without anyone remembering to add a case.
#
# Written after three review rounds in one class: `single_type_for`'s `TYPE_MAP.key?` hashed the token, and a
# sweep prompted by that finding then turned up seven more sites — `object_typed_element?`,
# `member_keyed_object_type?`, `single_contents_schema`, `json_type_for`, `object_type_branches`,
# `boolean_coercion_can_flip_truthiness?` and the shape-property base — each asking `is_a?`/`<`/`<=`/`==` of
# the token, plus `model_id_property` reading its `name` into prose.
#
# ONE DELIBERATE EXCEPTION (PRO-3384), not reachable from THIS spec: `model_id_type_token` dispatches
# `klass.primary_key` and `klass.type_for_attribute` — genuinely the token's own code — but only when
# `klass`'s ancestry NATIVELY includes `ActiveRecord::Base` (`NativeMethods.includes_module?`, never
# `klass < ActiveRecord::Base`, which the token could override) and the finder is the default `:find`. This
# suite never loads ActiveRecord, so the probe token below can never enter that branch and this spec cannot
# be the one that catches a regression there; the positive control — proving the branch is reached, and
# that a `primary_key` which itself raises still falls back to the untyped property rather than taking
# `input_schema` down — lives in `spec_rails/dummy_app/spec/axn/internal/reflection/model_id_type_spec.rb`.
module ReflectionDispatchProbe
  # Everything a classification or a rendering could reach. `to_ary`/`to_a` are absent for a mechanical reason
  # rather than a policy one: defining them on a Class leaves no `super` to call, so they cannot be
  # instrumented this way. Their remaining sites are `Kernel#Array`'s, tracked as PRO-3233 and visible here as
  # the `respond_to?` probe that `Kernel#Array` makes before it wraps.
  WATCHED = %i[
    hash eql? == != is_a? kind_of? instance_of? inspect to_s name <=> < <= > >=
    ancestors superclass instance_methods method_defined? public_method_defined? instance_method
    allocate new === dup clone each map to_h to_str to_sym
  ].freeze

  # `Kernel#Array` asks `respond_to?(:to_ary)` and then `respond_to?(:to_a)`, and Ruby routes an absent name
  # through `respond_to_missing?`. Those are the ONLY dispatches this spec tolerates, and only because the
  # `Kernel#Array` calls behind them are a separate, reported class (PRO-3233). Every other name is a failure:
  # a classification that asks the token about itself lets it decide what schema it gets, and one that raises
  # replaces the reflection with the caller's exception.
  TOLERATED = %i[respond_to? respond_to_missing?].freeze

  def self.instrumented(log)
    Class.new(::Array) do
      WATCHED.each do |name|
        define_singleton_method(name) do |*args, &blk|
          log << name
          super(*args, &blk)
        end
      end
      define_singleton_method(:respond_to?) do |name, *rest|
        log << :respond_to?
        super(name, *rest)
      end
      define_singleton_method(:find) { |_id| nil }
    end
  end

  POSITIONS = {
    "type: T" => ->(t) { { type: t } },
    "type: { klass: T }" => ->(t) { { type: { klass: t } } },
    "type: T in a union" => ->(t) { { type: [::Array, t] } },
    "type: T, gated" => ->(t) { { type: { klass: t, if: -> { false } } } },
    "of: T" => ->(t) { { type: ::Array, of: t } },
    "of: { klass: T }" => ->(t) { { type: ::Array, of: { klass: t } } },
    "of: { values: T }" => ->(t) { { type: ::Hash, of: { values: t } } },
    "model: T" => ->(t) { { model: t } },
    "type: T + absence ceiling" => ->(t) { { type: t, presence: false, absence: true } },
    "type: T + length bounds" => ->(t) { { type: t, presence: false, length: { minimum: 1, maximum: 3 } } },
    "type: T + inclusion set" => ->(t) { { type: t, presence: false, inclusion: { in: [[]] } } },
  }.freeze
  # `coerce:` has no entry here on purpose: the coercible types are a closed list of core classes, so a
  # declaration naming a caller's class beside it is refused outright and no token of ours can reach that path.
end

RSpec.describe "reflection never dispatches to a declared type token" do
  ReflectionDispatchProbe::POSITIONS.each do |label, build|
    it "runs none of the token's own code while reflecting #{label}" do
      log = []
      token = ReflectionDispatchProbe.instrumented(log)
      action = Class.new do
        include Axn
        def call; end
      end
      action.expects(:f, **build.call(token))
      action.exposes(:g, **build.call(token))
      log.clear

      action.input_schema
      action.output_schema

      expect(log.uniq - ReflectionDispatchProbe::TOLERATED).to be_empty
    end
  end
end

# The same derivation for an authored `description:`. A description is PROSE — the emitter reads its bytes
# to write them into a document and has no legitimate reason to ask it anything — so unlike a `default:` or
# an `inclusion:` member (whose blankness the emitter must genuinely consult) the tolerated set here is
# EMPTY, and the assertion needs no exclusion list that could hide a new site.
#
# It earns its place on the residue paths: a description is the String a residue clause is appended to, so
# every stand-down, projection and merge reads one while composing the report — and five separate reads of
# it (`to_s`, `==`, two `nil?`, and the `true`/`false` test beside it) each took `input_schema` down with
# the caller's own exception before this existed.
module DescriptionDispatchProbe
  WATCHED = %i[
    nil? == != eql? hash to_s to_str inspect to_json dup clone frozen? freeze length size empty?
    encoding valid_encoding? ascii_only? encode each bytes chars <=> =~ + * % respond_to?
  ].freeze

  def self.instrumented(log)
    Class.new(::String) do
      WATCHED.each do |name|
        define_method(name) do |*args, &blk|
          log << name
          super(*args, &blk)
        end
      end
    end
  end

  # Each shape puts the prose somewhere a residue path reads it. The transforming pair covers the stand-down
  # and the description carried through it; the gated pair covers the projection; the last is the ordinary
  # no-residue node, which must be just as quiet.
  SHAPES = {
    "a transforming stand-down" => lambda { |prose|
      Class.new do
        include Axn
        expects(:payload, type: Hash) { field :inner, type: String }
        expects :inner, on: :payload, type: String, optional: true, description: prose, preprocess: ->(v) { v }
        def call; end
      end
    },
    "a transforming stand-down with prose on both sides" => lambda { |prose|
      Class.new do
        include Axn
        expects(:payload, type: Hash) { field :inner, type: String, description: prose }
        expects :inner, on: :payload, type: String, optional: true, description: prose, preprocess: ->(v) { v }
        def call; end
      end
    },
    "a gated projection" => lambda { |prose|
      Class.new do
        include Axn
        expects(:payload, type: Hash) { field :inner, type: String }
        expects :inner, on: :payload, type: String, optional: true, description: prose,
                        length: { minimum: 5, if: -> { false } }
        def call; end
      end
    },
    "an ordinary node carrying no residue" => lambda { |prose|
      Class.new do
        include Axn
        expects :f, type: String, optional: true, description: prose
        def call; end
      end
    },
  }.freeze
end

RSpec.describe "reflection never dispatches to an authored description:" do
  DescriptionDispatchProbe::SHAPES.each do |label, build|
    it "runs none of the description's own code while reflecting #{label}" do
      log = []
      prose = DescriptionDispatchProbe.instrumented(log).new("authored prose")
      action = build.call(prose)
      log.clear

      action.input_schema

      expect(log.uniq).to be_empty
    end
  end
end
