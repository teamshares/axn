# frozen_string_literal: true

require "spec_helper"

# Base class that includes Action::Core
class BaseAction
  include Action::Core

  expects :data

  on_error :handle_error

  def call
    fail!("Something went wrong")
  end

  private

  def handle_error(error)
    @error_handled = true
    @error_message = error.message
  end
end

# Child class that inherits from BaseAction
class ChildAction < BaseAction
  on_error :child_error_handler

  def call
    fail!("Child error")
  end

  private

  def child_error_handler(error)
    @child_error_handled = true
    @child_error_message = error.message
  end
end

# Another child with different callback pattern
class BlockChildAction < BaseAction
  on_error do |error|
    @block_error_handled = true
    @block_error_message = error.message
  end

  def call
    fail!("Block child error")
  end
end

RSpec.describe "Inheritance with symbol callbacks" do
  describe "BaseAction" do
    it "handles errors with symbol callback" do
      result = BaseAction.call(data: "test")

      expect(result).not_to be_ok
      expect(result.error).to eq("Something went wrong")

      # The callback should have been called
      action = result.__action__
      expect(action.instance_variable_get(:@error_handled)).to be true
      expect(action.instance_variable_get(:@error_message)).to eq("Something went wrong")
    end
  end

  describe "ChildAction" do
    it "handles errors with symbol callback in inherited class" do
      result = ChildAction.call(data: "test")

      expect(result).not_to be_ok
      expect(result.error).to eq("Child error")

      # Both callbacks should have been called
      action = result.__action__
      expect(action.instance_variable_get(:@error_handled)).to be true
      expect(action.instance_variable_get(:@error_message)).to eq("Child error")
      expect(action.instance_variable_get(:@child_error_handled)).to be true
      expect(action.instance_variable_get(:@child_error_message)).to eq("Child error")
    end
  end

  describe "BlockChildAction" do
    it "handles errors with block callback in inherited class" do
      result = BlockChildAction.call(data: "test")

      expect(result).not_to be_ok
      expect(result.error).to eq("Block child error")

      # Both callbacks should have been called
      action = result.__action__
      expect(action.instance_variable_get(:@error_handled)).to be true
      expect(action.instance_variable_get(:@error_message)).to eq("Block child error")
      expect(action.instance_variable_get(:@block_error_handled)).to be true
      expect(action.instance_variable_get(:@block_error_message)).to eq("Block child error")
    end
  end

  describe "callback inheritance behavior" do
    it "registers callbacks from both parent and child classes" do
      # Check that both classes have their callbacks registered
      expect(BaseAction._callbacks_registry.for(:error).length).to eq(1)
      expect(ChildAction._callbacks_registry.for(:error).length).to eq(2)
      expect(BlockChildAction._callbacks_registry.for(:error).length).to eq(2)
    end

    it "executes callbacks in the correct order" do
      result = ChildAction.call(data: "test")
      action = result.__action__

      # Both callbacks should execute
      expect(action.instance_variable_get(:@error_handled)).to be true
      expect(action.instance_variable_get(:@child_error_handled)).to be true
    end
  end
end
