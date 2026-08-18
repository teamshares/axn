# frozen_string_literal: true

require "axn/core/context/facade"
require "axn/core/context/facade_inspector"
require "axn/internal/identity"

module Axn
  # Outbound / External ContextFacade
  class Result < Axn::Core::ContextFacade
    def initialize(...)
      super
      _define_boolean_predicate_readers
    end

    # For ease of mocking return results in tests
    class << self
      def ok(msg = nil, **exposures)
        exposes = exposures.keys.to_h { |key| [key, { optional: true }] }

        Axn::Factory.build(exposes:, success: msg, auto_log: false) do
          exposures.each do |key, value|
            expose(key, value)
          end
        end.call
      end

      def error(msg = nil, **exposures, &block)
        exposes = exposures.keys.to_h { |key| [key, { optional: true }] }

        Axn::Factory.build(exposes:, error: msg, auto_log: false) do
          exposures.each do |key, value|
            expose(key, value)
          end
          if block_given?
            begin
              block.call
            rescue StandardError => e
              # Set the exception directly without triggering on_exception handlers
              @__context.__record_exception(e)
            end
          else
            fail! msg, standalone: true
          end
        end.call
      end
    end

    # External interface
    delegate :ok?, :exception, :elapsed_time, :finalized?, to: :context

    # Memoized once the context is finalized, so resolution (which can invoke user-supplied message
    # blocks) runs a single time across the lifecycle (logging) and every caller read. A Result is the
    # SAME object during and after the run, so we must NOT cache a pre-finalization read — e.g. a hook
    # touching `result.success`/`#message` mid-run, where `ok?` is still true but a later `done!`/expose
    # would change the answer. Pre-finalization reads resolve live; only a finalized result is frozen in.
    def error
      return if ok? # (!ok? implies finalized — a failure sets the finalized flag — but be explicit)
      return _resolve_error unless finalized?

      @__resolved_error = _resolve_error unless defined?(@__resolved_error)
      @__resolved_error
    end

    def success
      return unless ok?
      return _resolve_success unless finalized?

      @__resolved_success = _resolve_success unless defined?(@__resolved_success)
      @__resolved_success
    end

    def message = exception ? error : success

    # Outcome constants for action execution results
    OUTCOMES = [
      OUTCOME_SUCCESS = "success",
      OUTCOME_FAILURE = "failure",
      OUTCOME_EXCEPTION = "exception",
    ].freeze

    # Deliberately NOT memoized (unlike #error/#success): outcome reflects classification state that
    # can finalize at different points during dispatch (records #2/#3 below), so a value read early —
    # e.g. by an ancestor's on_error before this level's context flag is set — must not be frozen in.
    # The recompute is cheap: it short-circuits on the common paths and only allocates a StringInquirer.
    def outcome
      label = if Axn::Internal::Identity.kind?(exception, Axn::Failure)
                OUTCOME_FAILURE
              elsif exception
                # Three records of "this settled as a failure", in priority order:
                #   1. context flag — durable; survives after the per-execution set is cleared.
                #   2. live classification set — set as soon as ANY action (this one or a nested one,
                #      sticky) classifies the exception. Covers the window where an ancestor's `on_error`
                #      reads outcome *before* the executor sets the context flag on this level.
                #   3. `_fails_on?` — defensive recompute.
                failure = @context.__classified_as_failure? ||
                          Internal::ExceptionClassification.failure?(exception) ||
                          action.class._fails_on?(exception) ||
                          Axn::ValidationError.user_facing?(exception)
                failure ? OUTCOME_FAILURE : OUTCOME_EXCEPTION
              else
                OUTCOME_SUCCESS
              end

      ActiveSupport::StringInquirer.new(label)
    end

    # Internal accessor for the underlying action instance (used by introspection and tests). It is a
    # reserved public field — see reserved_attribute_names_spec — so it stays public.
    def __action__ = @action

    # Internal accessor for the keys this result genuinely carries a value for, as opposed to the
    # ones it merely declared. `declared_fields` is the static contract and includes a key with no
    # value anywhere, whose reader reads nil; this instead reports a key as present the moment the
    # body exposes it directly, an outbound `default:` supplies it, or a matching `expects`+`exposes`
    # auto-copies it — all three mean the result reads a real value for that key. Absorbing one
    # result's values into another action keys on this, so a field the result never actually
    # populated does not write nil over a value the target already holds. A reserved public field,
    # like __action__ — see reserved_attribute_names_spec.
    def __exposed_keys__ = @context.exposed_data.keys

    # The outcome keys a pattern match sees, and how each is read. `deconstruct_keys` BUILDS the hash
    # from this map rather than repeating it, so the exposures guard (which refuses these names, since
    # the exposed data merged below would overwrite rather than append to them) reads exactly what is
    # emitted instead of predicting it.
    PATTERN_MATCH_KEYS = {
      ok: :ok?,
      success: :success,
      error: :error,
      message: :message,
      outcome: :_outcome_symbol,
      finalized: :finalized?,
    }.freeze

    # Enable pattern matching support for Ruby 3+
    def deconstruct_keys(keys)
      attrs = PATTERN_MATCH_KEYS.transform_values { |reader| send(reader) }

      # Add all exposed data
      attrs.merge!(@context.exposed_data)

      # Return filtered attributes if keys specified
      keys ? attrs.slice(*keys) : attrs
    end

    private

    # A pattern match binds the outcome as a plain Symbol; the public reader answers a StringInquirer.
    def _outcome_symbol = outcome.to_sym

    def _context_data_source = @context.exposed_data

    def _define_boolean_predicate_readers
      action.class.external_field_configs.each do |config|
        next unless declared_fields.include?(config.field)
        next unless config.boolean?

        _define_boolean_predicate_reader(config.field)
      end
    end

    def _define_boolean_predicate_reader(field)
      field_name = field.to_s
      return if field_name.end_with?("?")

      predicate_name = "#{field_name}?"
      # Private methods count, as they do at the inbound definition site (`_reader_name_available?`):
      # a name Result answers to privately (`_fail_standalone?`) is exactly the kind an alias must not
      # take, since Result dispatches it on itself. Declaration refuses such a pair outright
      # (_reject_shadowed_predicate_name!); this stays as the definition-site backstop.
      return if singleton_class.method_defined?(predicate_name) || singleton_class.private_method_defined?(predicate_name)

      singleton_class.alias_method predicate_name, field
    end

    # Memoized so resolution and _error_from_declared_source? share one resolver instance — message
    # blocks (and base resolution) run once, not twice. Only built when there's an exception (error
    # resolution is gated on !ok?), and exception/registry are fixed for a Result's lifetime.
    def _error_resolver = @_error_resolver ||= _msg_resolver(:error, exception:)

    # Whether result.error came from a declared base/reason rather than the bare generic fallback.
    # The executor uses this to decide whether an unexpected exception's presentation is worth
    # carrying to an ancestor (a baseless level that only produced the fallback contributes nothing).
    # Keys off declaration, NOT the resolved text — so a base/reason that legitimately resolves to the
    # default copy (e.g. `error "Something went wrong"`) is still recognized as declared and carried.
    #
    # Each read is plain TRUTHINESS, because its producer has already answered whether anything was supplied
    # and answered it undispatched: `_user_provided_error_message` normalizes an absent reason to nil below,
    # and `MessageResolver#body_for` does the same for a base. A second `present?` here put the caller's own
    # `blank?` back onto the path — `fail!` takes an arbitrary object, and this runs from `call!` while a
    # child's failure is bubbling — so a reason that could not answer it replaced that deliberate failure with
    # its own exception, settling the PARENT as an exception outcome with the child's failure intact
    # underneath.
    def _error_from_declared_source?
      return false if ok?
      return true if _user_provided_error_message
      return true if _error_resolver.base_message

      !_error_resolver.matched_reason.nil?
    end

    def _resolve_error
      resolver = _error_resolver

      # Ancestor of a bubbled failure: the child already resolved its full presentation.
      carried = Internal::CarriedPresentation.get(exception)
      if carried
        # This level's OWN matching reason (a conditional/dynamic `error`, possibly `standalone: true`)
        # takes precedence over the bubbled child — preserving the default-with-specific-overrides
        # pattern for bubbled failures (e.g. a parent `error "Record not found", if: NotFoundError`
        # around `Child.call!`). Only when this level declares nothing specific do we attach our base
        # onto the carried child message (a baseless ancestor's with_base is a no-op pass-through).
        descriptor, matched = resolver.matched_reason
        return descriptor.standalone? ? matched : resolver.with_base(matched) if descriptor

        return resolver.with_base(carried)
      end

      # Originating level (no carried presentation yet): unchanged behavior.
      reason = _user_provided_error_message
      return resolver.resolve_message unless reason

      _fail_standalone? ? reason : resolver.with_base(reason)
    end

    def _resolve_success
      reason = _user_provided_success_message
      resolver = _msg_resolver(:success, exception: nil)
      return resolver.resolve_message unless reason

      # The standalone opt-out is read from the context flag (not action-scoped like _fail_standalone?)
      # because a child `done!` never bubbles as an EarlyCompletion through a parent — `call!` swallows
      # it and returns an ok result — so this flag only ever reflects THIS action's own opt-out.
      @context.__early_completion_standalone ? reason : resolver.with_base(reason)
    end

    def _user_provided_success_message
      @context.__early_completion_message.presence
    end

    def _user_provided_error_message
      # A user-facing validation failure (expects ..., user_facing:) surfaces its composed message as
      # an attachable reason, so a declared base `error` headlines it exactly like a `fail!` reason.
      return exception.user_facing_message.presence if Axn::ValidationError.user_facing?(exception)

      # Undispatched, like every other type test on this object: the exception is caller-supplied, this
      # runs while the failure is being reported and again on every later `result.error` read, and what
      # it gates is whether axn calls its own readers on the object at all.
      return unless Axn::Internal::Identity.kind?(exception, Axn::Failure)
      return if exception.default_message?

      # `supplied_reason`, not `raw_reason.presence`: the reason is the caller's object, this runs while the
      # failure is being reported, and `presence` dispatches the object's own `blank?` (see
      # `Axn::Failure#supplied_reason`).
      exception.supplied_reason
    end

    def _fail_standalone?
      # A user-facing validation reason attaches by default (no per-field opt-out yet — deferred),
      # so anything that isn't a fail! Failure is NOT standalone.
      return false unless Axn::Internal::Identity.kind?(exception, Axn::Failure)
      # standalone: is scoped to the action that called fail!. A bubbled child Failure resolved at an
      # ancestor still gets the ancestor's base (child opt-out is local) → not standalone here.
      return false unless exception.__originating_action.equal?(action)

      exception.standalone?
    end

    def method_missing(method_name, ...) # rubocop:disable Style/MissingRespondToMissing (because we're not actually responding to anything additional)
      if @context.__combined_data.key?(method_name.to_sym)
        msg = <<~MSG
          Method ##{method_name} is not available on Action::Result!

          #{action_name} may be missing a line like:
            exposes :#{method_name}
        MSG

        raise Axn::ContractViolation::MethodNotAllowed, msg
      end

      super
    end
  end
end
