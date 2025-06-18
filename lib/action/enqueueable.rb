# frozen_string_literal: true

require_relative "enqueueable/via_sidekiq"
require_relative "enqueueable/enqueue_all_in_background"

module Action
  module Enqueueable
    extend ActiveSupport::Concern

    included do
      include ViaSidekiq
      include EnqueueAllInBackground
    end
  end
end
