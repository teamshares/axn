# frozen_string_literal: true

module Axn
  module Core
    class Context
      def initialize(**provided_data)
        # Normalize inbound keys to symbols so the read path has indifferent access: a declared field's
        # key (always symbolized at declaration) matches the call-arg key regardless of how the caller
        # spelled it. Splatting JSON/HTTP params straight into `.call(**body)` (string keys) Just Works
        # instead of silently reading nil. Top-level keys only — values (including nested hashes) are
        # untouched. Async deserialize paths already re-symbolize keys before re-invoking, so this is
        # consistent with the round-trip (see Axn::Async serialization). See PRO-2790.
        @provided_data = provided_data.transform_keys(&:to_sym)
        @exposed_data = {}

        # Framework-managed fields
        @failure = false
        @exception = nil
        @elapsed_time = nil
        @early_completion_standalone = false
      end

      # Framework state methods
      def ok? = !@failure
      def failed? = @failure || false
      def finalized? = @finalized || false

      # Framework field accessors
      attr_accessor :provided_data, :exposed_data, :elapsed_time
      attr_reader :exception
      private :elapsed_time=

      #
      # Here down intended for internal use only
      #

      # INTERNAL: base for further filtering (for logging) or providing user with usage hints
      def __combined_data = @provided_data.merge(@exposed_data)

      def __early_completion? = @early_completion || false

      # Deliberately does NOT finalize. `_settle_exception!` still has to decide failure-vs-exception
      # after this runs — via `fails_on if:`/`unless:`, which can call arbitrary user code, including
      # a condition that reads `result.outcome` reentrant. If `finalized?` were already true here,
      # that reentrant read would memoize whatever `outcome` resolves to BEFORE classification is
      # decided — permanently, since a memoized value never recomputes. The executor finalizes
      # explicitly (`__finalize!`) once classification is fully decided and recorded, so `outcome`
      # keeps recomputing live until there is an actual verdict to freeze in. `ok?`/`exception` are
      # unaffected: `@failure`/`@exception` are set here, same as before.
      def __record_exception(e)
        @exception = e
        @failure = true
      end

      # Recorded by the executor when an exception settles as a *failure* (a `fail!`, a `fails_on` match,
      # or a nested `fails_on` made sticky) rather than an unhandled exception. result.outcome reads this
      # so the failure/exception distinction survives after the per-execution classification set is cleared.
      def __classify_as_failure! = @classified_as_failure = true
      def __classified_as_failure? = @classified_as_failure || false

      def __record_early_completion(message, standalone: false)
        # Only store a real (non-sentinel) message, but always record the standalone opt-out so a bare
        # `done!(standalone: true)` isn't silently dropped (it's moot when no message resolves, but the
        # flag must reflect the call rather than retain the default).
        @early_completion_message = message unless message == Axn::Internal::EarlyCompletion.new.message
        @early_completion_standalone = standalone
        @early_completion = true
        @finalized = true
      end

      def __early_completion_message = @early_completion_message.presence
      def __early_completion_standalone = @early_completion_standalone

      def __finalize!
        @finalized = true
      end
    end
  end
end
