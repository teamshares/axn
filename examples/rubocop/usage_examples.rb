# frozen_string_literal: true

# This file demonstrates various Axn usage patterns
# Run RuboCop on this file to see the custom cop in action

# ❌ BAD: Missing result check - will trigger offense
class BadOuterAction
  include Axn

  def call
    InnerAction.call(param: "value") # Offense: Use `call!` or check `result.ok?`
    # This will always continue even if InnerAction fails
  end
end

# ❌ BAD: Result assigned but never checked - will trigger offense
class AnotherBadAction
  include Axn

  def call
    # rubocop:disable Lint/UselessAssignment
    result = InnerAction.call(param: "value") # Offense: Use `call!` or check `result.ok?`
    # rubocop:enable Lint/UselessAssignment
    # result is assigned but never checked
  end
end

# ✅ GOOD: Using call! - no offense
class GoodBangAction
  include Axn

  def call
    InnerAction.call!(param: "value") # Good: Using call! ensures exceptions bubble up
  end
end

# ✅ GOOD: Checking result.ok? - no offense
class GoodCheckAction
  include Axn

  def call
    result = InnerAction.call(param: "value")
    result unless result.ok?
    # Process successful result...
  end
end

# ✅ GOOD: Checking result.failed? - no offense
class GoodFailedCheckAction
  include Axn

  def call
    result = InnerAction.call(param: "value")
    return unless result.failed?

    result

    # Process successful result...
  end
end

# ✅ GOOD: Accessing result.error - no offense
class GoodErrorCheckAction
  include Axn

  def call
    result = InnerAction.call(param: "value")
    return unless result.error

    result

    # Process successful result...
  end
end

# ✅ GOOD: Returning the result - no offense
class GoodReturnAction
  include Axn

  def call
    InnerAction.call(param: "value")
    # Good: Result is returned, so it's properly handled
  end
end

# ✅ GOOD: Using result in expose - no offense
class GoodExposeAction
  include Axn

  exposes :nested_result

  def call
    result = InnerAction.call(param: "value")
    expose nested_result: result # Good: Result is used, so it's properly handled
  end
end

# ✅ GOOD: Passing result to another method - no offense
class GoodMethodPassAction
  include Axn

  def call
    result = InnerAction.call(param: "value")
    process_result(result) # Good: Result is used, so it's properly handled
  end

  private

  def process_result(result)
    # Process the result
  end
end

# ✅ GOOD: Complex conditional handling - no offense
class GoodComplexAction
  include Axn

  def call
    result = InnerAction.call(param: "value")

    if result.ok?
      process_success(result)
    else
      handle_failure(result)
    end
  end

  private

  def process_success(result)
    # Handle success case
  end

  def handle_failure(result)
    # Handle failure case
  end
end

# ✅ GOOD: Early return pattern - no offense
class GoodEarlyReturnAction
  include Axn

  def call
    result = InnerAction.call(param: "value")
    return result unless result.ok?

    another_result = AnotherAction.call(param: "value")
    another_result unless another_result.ok?

    # Process both successful results...
  end
end

# ✅ GOOD: Multiple Action calls with proper handling - no offense
class GoodMultipleActionsAction
  include Axn

  def call
    user_result = UserAction.call(user_id: params[:user_id])
    return user_result unless user_result.ok?

    order_result = OrderAction.call(user: user_result.user)
    return order_result unless order_result.ok?

    # Process both successful results...
    expose user: user_result.user, order: order_result.order
  end
end

# ❌ BAD: Axn call outside of call method - no offense (cop only checks call method)
class MixedAction
  include Axn

  def call
    # This is fine
    result = InnerAction.call(param: "value")
    result unless result.ok?
  end

  def other_method
    InnerAction.call(param: "value") # No offense: not in call method
  end
end

# ❌ BAD: Action call in regular class - no offense (cop only checks Axn classes)
class RegularClass
  def some_method
    InnerAction.call(param: "value") # No offense: not in Axn class
  end
end
