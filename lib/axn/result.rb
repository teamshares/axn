# frozen_string_literal: true

require "axn/core/context/facade"
require "axn/core/context/facade_inspector"

module Axn
  # Outbound / External ContextFacade
  class Result < ContextFacade
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
            fail! msg, prefixed: false
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
      label = if exception.is_a?(Axn::Failure)
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

    # Enable pattern matching support for Ruby 3+
    def deconstruct_keys(keys)
      attrs = {
        ok: ok?,
        success:,
        error:,
        message:,
        outcome: outcome.to_sym,
        finalized: finalized?,
      }

      # Add all exposed data
      attrs.merge!(@context.exposed_data)

      # Return filtered attributes if keys specified
      keys ? attrs.slice(*keys) : attrs
    end

    private

    def _context_data_source = @context.exposed_data

    def _define_boolean_predicate_readers
      action.external_field_configs.each do |config|
        next unless declared_fields.include?(config.field)
        next unless Axn::Internal::FieldConfig.boolean?(config)

        _define_boolean_predicate_reader(config.field)
      end
    end

    def _define_boolean_predicate_reader(field)
      field_name = field.to_s
      return if field_name.end_with?("?") || field_name.include?(".")

      predicate_name = "#{field_name}?"
      return if singleton_class.method_defined?(predicate_name)

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
    def _error_from_declared_source?
      return false if ok?
      return true if _user_provided_error_message.present?

      _error_resolver.base_message.present? || !_error_resolver.matched_reason.nil?
    end

    def _resolve_error
      resolver = _error_resolver

      # Ancestor of a bubbled failure: the child already resolved its full presentation.
      carried = Internal::CarriedPresentation.get(exception)
      if carried
        # This level's OWN matching reason (a conditional/dynamic `error`, possibly `prefixed: false`)
        # takes precedence over the bubbled child — preserving the default-with-specific-overrides
        # pattern for bubbled failures (e.g. a parent `error "Record not found", if: NotFoundError`
        # around `Child.call!`). Only when this level declares nothing specific do we prefix our base
        # onto the carried child message (a baseless ancestor's with_base_prefix is a no-op pass-through).
        descriptor, matched = resolver.matched_reason
        return descriptor.prefixed? ? resolver.with_base_prefix(matched) : matched if descriptor

        return resolver.with_base_prefix(carried)
      end

      # Originating level (no carried presentation yet): unchanged behavior.
      reason = _user_provided_error_message
      return resolver.resolve_message unless reason

      _fail_prefixed? ? resolver.with_base_prefix(reason) : reason
    end

    def _resolve_success
      reason = _user_provided_success_message
      resolver = _msg_resolver(:success, exception: nil)
      return resolver.resolve_message unless reason

      # The prefixed opt-out is read from the context flag (not action-scoped like _fail_prefixed?)
      # because a child `done!` never bubbles as an EarlyCompletion through a parent — `call!` swallows
      # it and returns an ok result — so this flag only ever reflects THIS action's own opt-out.
      @context.__early_completion_prefixed ? resolver.with_base_prefix(reason) : reason
    end

    def _user_provided_success_message
      @context.__early_completion_message.presence
    end

    def _user_provided_error_message
      # A user-facing validation failure (expects ..., user_facing:) surfaces its composed message as
      # a prefixable reason, so a declared base `error` headlines it exactly like a `fail!` reason.
      return exception.user_facing_message.presence if Axn::ValidationError.user_facing?(exception)

      return unless exception.is_a?(Axn::Failure)
      return if exception.default_message?

      exception.raw_reason.presence
    end

    def _fail_prefixed?
      # A user-facing validation reason is prefixed-by-default (no per-field opt-out yet — deferred),
      # so anything that isn't a `fail!` Failure prefixes.
      return true unless exception.is_a?(Axn::Failure)
      # `prefixed: false` is scoped to the action that called `fail!`. A bubbled child Failure
      # resolved at an ancestor still gets the ancestor's base prefix (child opt-out is local).
      return true unless exception.__originating_action.equal?(action)

      exception.prefixed?
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
