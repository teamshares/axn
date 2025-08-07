# frozen_string_literal: true

# NOTE: This is a temporary file to be removed when we have a better way to handle context.
# rubocop:disable Style/OpenStructUse, Style/CaseEquality
require "ostruct"

module Action
  class Context < OpenStruct
    def self.build(context = {})
      self === context ? context : new(context)
    end

    def success?
      !failure?
    end

    def failure?
      @failure || false
    end

    def fail!(context = {})
      context.each { |key, value| self[key.to_sym] = value }
      @failure = true
      raise Action::Failure, self
    end
  end
end
# rubocop:enable Style/OpenStructUse, Style/CaseEquality
