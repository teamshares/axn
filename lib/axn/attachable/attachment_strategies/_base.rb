# frozen_string_literal: true

require "ostruct"

module Axn
  module Attachable
    class AttachmentStrategies
      # Base module for all attachment strategies
      module Base
        # Class-level hooks for strategy modules to configure themselves
        def preprocess_kwargs(**kwargs) = kwargs
        def strategy_specific_kwargs = []

        # The actual per-strategy mounting logic
        def mount(descriptor:, target:) = raise NotImplementedError, "Strategy modules must implement mount"

        def key = name.split("::").last.underscore.to_sym
      end
    end
  end
end
