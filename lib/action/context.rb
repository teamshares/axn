# frozen_string_literal: true

module Action
  class Context
    attr_accessor :provided_data, :exposed_data

    def initialize(**provided_data)
      @provided_data = provided_data
      @exposed_data = {}
      @failure = false
      # Framework-managed fields
      @exception = nil
      @error_from_user = nil
      @error_prefix = nil
      @elapsed_time = nil
    end

    # Hash conversion for logging - combines both data sets
    def to_h
      @provided_data.merge(@exposed_data)
    end

    # Framework state methods
    def success? = !@failure
    def failure? = @failure || false

    # Framework field accessors
    attr_accessor :exception, :error_from_user, :error_prefix, :elapsed_time

    # Internal failure state setter (for framework use)
    attr_writer :failure
    private :failure=
  end
end
