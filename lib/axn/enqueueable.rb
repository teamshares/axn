# frozen_string_literal: true

require "axn/enqueueable/via_sidekiq"
require "axn/enqueueable/via_activejob"
require "axn/enqueueable/null_implementation"

module Axn
  module Enqueueable
    extend ActiveSupport::Concern

    included do
      if defined?(ActiveJob)
        include ViaActiveJob
      elsif defined?(Sidekiq)
        include ViaSidekiq
      else
        include NullImplementation
      end
    end
  end
end
