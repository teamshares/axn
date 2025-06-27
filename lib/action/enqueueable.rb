# frozen_string_literal: true

require_relative "enqueueable/via_sidekiq"

module Action
  module Enqueueable
    extend ActiveSupport::Concern

    included do
      include ViaSidekiq
    end
  end
end
