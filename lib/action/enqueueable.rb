# frozen_string_literal: true

require "action/enqueueable/via_sidekiq"

module Action
  module Enqueueable
    extend ActiveSupport::Concern

    included do
      include ViaSidekiq
    end
  end
end
