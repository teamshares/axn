# frozen_string_literal: true

module Actions
  class TestAction
    include Axn

    def call
      # Just complete successfully - the result is automatically created
      # The success message will be the default "Action completed successfully"
    end
  end
end
