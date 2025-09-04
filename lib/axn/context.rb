# frozen_string_literal: true

module Axn
  class Context
    attr_accessor :provided_data, :exposed_data

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

    # Framework field accessors
    attr_accessor :elapsed_time
    attr_reader :exception
    private :elapsed_time=

    # INTERNAL: base for further filtering (for logging) or providing user with usage hints
    def __combined_data = @provided_data.merge(@exposed_data)

    def __record_exception(e)
      @exception = e
      @failure = true
    end
  end
end
