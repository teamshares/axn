# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Constant name collision handling" do
  describe "steps" do
    let(:test_class) do
      build_axn do
        # These step names would both become 'Step1' after gsub
        step "Step 1", expects: [], exposes: [:value] do
          expose :value, "first"
        end

        step "Step1", expects: [], exposes: [:value] do
          expose :value, "second"
        end

        # These would both become 'Step2'
        step "Step 2", expects: [], exposes: [:value] do
          expose :value, "third"
        end

        step "Step2", expects: [], exposes: [:value] do
          expose :value, "fourth"
        end
      end
    end

    it "should handle constant name collisions gracefully" do
      # This should not raise an error about redefining constants
      expect { test_class }.not_to raise_error

      # Both steps should be accessible (Step1 and Step11 due to collision handling)
      expect(test_class::AttachedAxns.constants).to include(:Step1, :Step11)

      # The steps should work correctly and return different values
      result1 = test_class::AttachedAxns::Step1.call
      result2 = test_class::AttachedAxns::Step11.call

      expect(result1).to be_ok
      expect(result2).to be_ok

      # This is the key test - they should return different values
      expect(result1.value).to eq("first")
      expect(result2.value).to eq("second")
    end

    it "should not add numbers when there's no collision" do
      no_collision_class = build_axn do
        step "Step1", expects: [], exposes: [:value] do
          expose :value, "first"
        end

        step "Step2", expects: [], exposes: [:value] do
          expose :value, "second"
        end
      end

      # Should have exactly Step1 and Step2, no numbers
      constants = no_collision_class::AttachedAxns.constants.grep(/^Step\d*$/)
      expect(constants).to contain_exactly(:Step1, :Step2)
    end

    it "should increment numbers properly for multiple collisions" do
      multiple_collision_class = build_axn do
        # All of these would become 'Step1' after gsub
        step "Step1", expects: [], exposes: [:value] do
          expose :value, "first"
        end

        step "Step 1", expects: [], exposes: [:value] do
          expose :value, "second"
        end

        step "Step1", expects: [], exposes: [:value] do
          expose :value, "third"
        end
      end

      # Should have Step1, Step11, Step12
      constants = multiple_collision_class::AttachedAxns.constants.grep(/^Step\d*$/)
      expect(constants).to contain_exactly(:Step1, :Step11, :Step12)

      # Verify they return different values
      expect(multiple_collision_class::AttachedAxns::Step1.call.value).to eq("first")
      expect(multiple_collision_class::AttachedAxns::Step11.call.value).to eq("second")
      expect(multiple_collision_class::AttachedAxns::Step12.call.value).to eq("third")
    end

    it "should handle spaces and special characters in step names" do
      collision_class = build_axn do
        step "My Step", expects: [], exposes: [:value] do
          expose :value, "my step"
        end

        step "MyStep", expects: [], exposes: [:value] do
          expose :value, "mystep"
        end

        step "My  Step", expects: [], exposes: [:value] do
          expose :value, "my double step"
        end
      end

      # This should not raise an error
      expect { collision_class }.not_to raise_error

      # All steps should be accessible with unique names
      constants = collision_class::AttachedAxns.constants.grep(/^MyStep\d*$/)
      expect(constants).to contain_exactly(:MyStep, :MyStep1, :MyStep2)
    end
  end

  describe "subactions" do
    it "should handle constant name collisions for subactions" do
      subaction_class = Class.new do
        include Axn::Attachable
        include Axn::Core::Flow

        # These would both become 'Test1' after gsub
        axn "test1", expects: [], exposes: [:value] do
          expose :value, "first"
        end

        axn "Test 1", expects: [], exposes: [:value] do
          expose :value, "second"
        end
      end

      # This should not raise an error
      expect { subaction_class }.not_to raise_error

      # Both subactions should be accessible
      expect(subaction_class::AttachedAxns.constants).to include(:Test1, :Test11)

      # The subactions should work correctly and return different values
      result1 = subaction_class::AttachedAxns::Test1.call
      result2 = subaction_class::AttachedAxns::Test11.call

      expect(result1).to be_ok
      expect(result2).to be_ok

      expect(result1.value).to eq("first")
      expect(result2.value).to eq("second")
    end

    it "should not add numbers when there's no collision for subactions" do
      no_collision_class = Class.new do
        include Axn::Attachable
        include Axn::Core::Flow

        axn "test1", expects: [], exposes: [:value] do
          expose :value, "first"
        end

        axn "test2", expects: [], exposes: [:value] do
          expose :value, "second"
        end
      end

      # Should have exactly Test1 and Test2, no numbers
      constants = no_collision_class::AttachedAxns.constants.grep(/^Test\d*$/)
      expect(constants).to contain_exactly(:Test1, :Test2)
    end
  end

  describe "edge cases" do
    it "should handle empty names gracefully" do
      empty_name_class = build_axn do
        step "", expects: [], exposes: [:value] do
          expose :value, "empty"
        end
      end

      expect { empty_name_class }.not_to raise_error
      expect(empty_name_class::AttachedAxns.constants).to include(:AnonymousAxn)
    end

    it "should handle names with only special characters" do
      special_char_class = build_axn do
        step "!!!", expects: [], exposes: [:value] do
          expose :value, "special"
        end
      end

      expect { special_char_class }.not_to raise_error
      expect(special_char_class::AttachedAxns.constants).to include(:AnonymousAxn)
    end

    it "should handle very long collision chains" do
      long_collision_class = build_axn do
        # Create 5 steps that would all become 'Step1'
        5.times do |i|
          step "Step 1", expects: [], exposes: [:value] do
            expose :value, "step_#{i + 1}"
          end
        end
      end

      expect { long_collision_class }.not_to raise_error

      # Should have Step1, Step11, Step12, Step13, Step14
      constants = long_collision_class::AttachedAxns.constants.grep(/^Step\d*$/)
      expect(constants).to contain_exactly(:Step1, :Step11, :Step12, :Step13, :Step14)

      # Verify all steps work
      expect(long_collision_class::AttachedAxns::Step1.call.value).to eq("step_1")
      expect(long_collision_class::AttachedAxns::Step11.call.value).to eq("step_2")
      expect(long_collision_class::AttachedAxns::Step12.call.value).to eq("step_3")
      expect(long_collision_class::AttachedAxns::Step13.call.value).to eq("step_4")
      expect(long_collision_class::AttachedAxns::Step14.call.value).to eq("step_5")
    end
  end
end
