# frozen_string_literal: true

module Actions::Clients
  class User
    include Axn

    axn_method(:get_name) { |id:| user(id:).name }
    axn(:email, expose_return_as: :value) { |id:| user(id:).email }

    private

    def user(id: nil)
      ::User.find(id || 1)
    end
  end
end
