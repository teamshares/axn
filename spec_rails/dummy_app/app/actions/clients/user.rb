# frozen_string_literal: true

module Actions::Clients
  class User
    include Axn

    module ApiHelpers
      def user(id: nil)
        ::User.find(id || 1)
      end
    end

    axn_method(:get_name, include: ApiHelpers) { |id:| user(id:).name }
    axn(:email, expose_return_as: :value, include: ApiHelpers) { |id:| user(id:).email }
  end
end
