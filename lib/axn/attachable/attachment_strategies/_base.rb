# frozen_string_literal: true

require "ostruct"

module Axn
  module Attachable
    class AttachmentStrategies
      # Base class for all attachment strategies
      class Base
        # Class-level hooks for subclasses to configure themselves
        def self.preprocess_kwargs(**kwargs) = kwargs
        def self.strategy_specific_kwargs = []

        # The actual per-strategy mounting logic
        def self.mount(descriptor:, target:) = raise NotImplementedError, "Subclasses must implement mount"

        def self.key = name.split("::").last.underscore.to_sym
      end
    end
  end
end
