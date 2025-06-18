# frozen_string_literal: true

# NOTE: this is a standalone worker for enqueueing all instances of a class.
# Unlike the other files in the folder, it is NOT included in the Action stack.

# Note it uses Axn-native enqueueing, so will automatically support additional
# backends as they are added (initially, just Sidekiq)

module Action
  module Enqueueable
    class EnqueueAllWorker
      include Action

      expects :klass_name, type: String

      def call
        klass_name.constantize.enqueue_all
      end
    end
  end
end
