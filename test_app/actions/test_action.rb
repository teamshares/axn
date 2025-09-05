# frozen_string_literal: true

class TestAction
  include Axn

  def call
    # This should be flagged
    InnerAction.call(param: "value")

    # This should also be flagged
    UserService.call(param: "value")

    # These should NOT be flagged
    proc { puts "hello" }.call
    Time.now.call if Time.respond_to?(:call)
    JSON.parse('{"key": "value"}').call if JSON.respond_to?(:call)
  end
end
