# frozen_string_literal: true

module Action
  module Enqueueable
    module EnqueueAllInBackground
      extend ActiveSupport::Concern

      module ClassMethods
        def enqueue_all_in_background
          raise NotImplementedError, "#{name} must implement a .enqueue_all method in order to use .enqueue_all_in_background" unless respond_to?(:enqueue_all)

          ::Action::Enqueueable::EnqueueAllWorker.enqueue(klass_name: name)
        end
      end
    end
  end
end
