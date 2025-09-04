# frozen_string_literal: true

require "axn/enqueueable/via_sidekiq"

module Axn
  module Enqueueable
    extend ActiveSupport::Concern

    included do
      include ViaSidekiq
    end
  end
end
