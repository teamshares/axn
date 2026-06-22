# frozen_string_literal: true

module Axn
  class Context
    def initialize(**provided_data)
      @provided_data = provided_data
      @exposed_data = {}

      # Framework-managed fields
      @failure = false
      @exception = nil
      @elapsed_time = nil
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

    def __record_exception(e)
      @exception = e
      @failure = true
      @finalized = true
    end

    # Recorded by the executor when an exception settles as a *failure* (a `fail!`, a `fails_on` match,
    # or a nested `fails_on` made sticky) rather than an unhandled exception. result.outcome reads this
    # so the failure/exception distinction survives after the per-execution classification set is cleared.
    def __classify_as_failure! = @classified_as_failure = true
    def __classified_as_failure? = @classified_as_failure || false

    def __record_early_completion(message, prefixed: true)
      unless message == Axn::Internal::EarlyCompletion.new.message
        @early_completion_message = message
        @early_completion_prefixed = prefixed
      end
      @early_completion = true
      @finalized = true
    end

    def __early_completion_message = @early_completion_message.presence
    def __early_completion_prefixed = @early_completion_prefixed.nil? ? true : @early_completion_prefixed

    def __finalize!
      @finalized = true
    end
  end
end
