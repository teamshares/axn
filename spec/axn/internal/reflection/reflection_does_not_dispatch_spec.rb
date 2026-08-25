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
