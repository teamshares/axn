# frozen_string_literal: true

module Actions::Clients
  class User
    include Axn

    # This is a fake method to simulate a client method
    def self.user(id: nil)
      ::User.find(id || 1)
    end

    axnable_method(:get_name) { |id:| self.class.user(id:).name }
    axn(:email, expose_return_as: :value) { |id:| user(id:).email }
  end
end
