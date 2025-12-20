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

    def __record_early_completion(message)
      @early_completion_message = message unless message == Axn::Internal::EarlyCompletion.new.message
      @early_completion = true
      @finalized = true
    end

    def __early_completion_message = @early_completion_message.presence

    def __finalize!
      @finalized = true
    end
  end
end
