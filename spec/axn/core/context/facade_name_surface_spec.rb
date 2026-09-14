# frozen_string_literal: true

require "axn/testing/spec_helpers"

# The context facade's method table IS the set of field names a declaration is refused: the wire-key
# guard asks `owner_within(Axn::Core::InternalContext, key)` and the exposure guard asks
# `owner_of(Axn::Result, name)`, both by ownership rather than from a list (see AGENTS.md). So every
# non-underscored helper added here quietly takes an ordinary domain word away from every author —
# which is how `context`, `action` and `action_name` came to be reserved while being private,
# undocumented and unreachable from an action (PRO-3423).
#
# Hence the invariant: the facade's own surface stays inside its own `_`-prefixed namespace, and a
# name that must keep its spelling is listed below with the reason it has to.
RSpec.describe "context facade name surface" do
  # Ruby (or axn) dispatches these by name, so they cannot be prefixed:
  # - initialize: Ruby invokes it from `new`
  # - method_missing: Ruby's own lookup fallback
  # - inspect: what a logger, a console and `Kernel#p` call
  # - fail!: the guard rail that tells an author to call fail! on the action, not the context. It is
  #   the one name here that could have been prefixed and deliberately is not — a field named `fail!`
  #   is unwriteable in the DSL anyway, so there is nothing to free.
  PROTOCOL_NAMES = %i[initialize method_missing inspect fail!].freeze # rubocop:disable Lint/ConstantDefinitionInBlock

  # Axn::Result's own public API is the one LEGITIMATE claim on the field namespace: `result.message`
  # has to mean the framework's message, so an exposure of that name genuinely cannot be allowed. It is
  # exempted by being named here — spelled out rather than computed from Result's own method table,
  # which would subtract whatever is there and assert nothing. A NEW unprefixed name on Result fails
  # this and has to be argued for, the same as anywhere else.
  #
  # (deconstruct_keys is Ruby's pattern-matching protocol; it is here rather than in PROTOCOL_NAMES
  # because Result is the only facade that implements it.)
  # rubocop:disable Lint/ConstantDefinitionInBlock
  RESULT_PUBLIC_API = %i[ok? success error message outcome exception elapsed_time finalized? deconstruct_keys].freeze
  # rubocop:enable Lint/ConstantDefinitionInBlock

  {
    Axn::Core::ContextFacade => [],
    Axn::Core::InternalContext => [],
    Axn::Result => RESULT_PUBLIC_API,
  }.each do |klass, permitted|
    it "#{klass} declares only underscored, protocol or explicitly-permitted names" do
      own = klass.instance_methods(false) + klass.private_instance_methods(false)
      offenders = own.reject do |name|
        name.to_s.start_with?("_") || PROTOCOL_NAMES.include?(name) || permitted.include?(name)
      end

      expect(offenders).to be_empty,
                           "#{klass} owns #{offenders.inspect}, which no `expects`/`exposes` may then use as a field " \
                           "name. Prefix with `_`, or list it above with the reason it cannot be."
    end
  end

  # The half the rule exists for: the six names the prefixing freed stay free, in both directions.
  # `expects` and `exposes` run through different guards, so both are asked.
  %i[context action action_name declared_fields default_error default_success].each do |name|
    it "leaves `#{name}` available to a field declaration" do
      expect { build_axn { expects name } }.not_to raise_error
      expect { build_axn { exposes name } }.not_to raise_error
    end
  end

  it "round-trips a field named after the facade's own internals" do
    action = build_axn do
      expects :context, :action
      exposes :context

      def call = expose(context: "#{context}/#{action}")
    end

    result = action.call(context: "quarterly", action: "review")

    expect(result).to be_ok
    expect(result.context).to eq("quarterly/review")
    # The renamed reader still answers the contract rather than the caller's value.
    expect(result.__declared_fields__).to eq([:context])
    expect(result.inspect).to include("context: \"quarterly/review\"")
  end
end
