# frozen_string_literal: true

module Actions
  class TestActionActiveJobNoArgs
    include Axn

    async :active_job

    def call
      info "Action executed with no arguments"
    end
  end
end
