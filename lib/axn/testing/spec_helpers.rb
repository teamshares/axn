# frozen_string_literal: true

module Axn
  module Testing
    module SpecHelpers
      def build_axn(&block)
        action = Class.new.send(:include, Axn)
        action.class_eval(&block) if block
        action
      end
    end
  end
end

if defined?(RSpec)
  RSpec.configure do |config|
    config.include Axn::Testing::SpecHelpers
  end
end
