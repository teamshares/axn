# frozen_string_literal: true

module Axn
  module Testing
    module SpecHelpers
      def build_action(&block)
        action = Class.new.send(:include, Axn)
        action.class_eval(&block) if block
        action
      end

      def build_axn(**, &)
        Axn::Factory.build(**, &)
      end
    end
  end
end

RSpec.configure do |config|
  config.include Axn::Testing::SpecHelpers
end
