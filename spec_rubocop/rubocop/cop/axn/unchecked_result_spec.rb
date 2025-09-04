# frozen_string_literal: true

require_relative "../../../spec_helper"
require_relative "../../../../lib/rubocop/cop/axn/unchecked_result"

RSpec.describe RuboCop::Cop::Axn::UncheckedResult do
  include RuboCop::RSpec::ExpectOffense
  subject(:cop) { described_class.new }

  context "when calling Axns from within Axn classes" do
    context "with proper result handling" do
      it "accepts result.ok? check" do
        expect_no_offenses(<<~RUBY)
          class OuterAction
            include Axn
            def call
              result = InnerAction.call(param: "value")
              return result unless result.ok?
              # Process successful result...
            end
          end
        RUBY
      end

      it "accepts result.failed? check" do
        expect_no_offenses(<<~RUBY)
          class OuterAction
            include Axn
            def call
              result = InnerAction.call(param: "value")
              if result.failed?
                return result
              end
              # Process successful result...
            end
          end
        RUBY
      end

      it "accepts result.error access" do
        expect_no_offenses(<<~RUBY)
          class OuterAction
            include Axn
            def call
              result = InnerAction.call(param: "value")
              if result.error
                return result
              end
              # Process successful result...
            end
          end
        RUBY
      end

      it "accepts result.exception access" do
        expect_no_offenses(<<~RUBY)
          class OuterAction
            include Axn
            def call
              result = InnerAction.call(param: "value")
              if result.exception
                return result
              end
              # Process successful result...
            end
          end
        RUBY
      end

      it "accepts result return" do
        expect_no_offenses(<<~RUBY)
          class OuterAction
            include Axn
            def call
              result = InnerAction.call(param: "value")
              result
            end
          end
        RUBY
      end

      it "accepts result used in expose" do
        expect_no_offenses(<<~RUBY)
          class OuterAction
            include Axn
            exposes :nested_result
            def call
              result = InnerAction.call(param: "value")
              expose nested_result: result
            end
          end
        RUBY
      end

      it "accepts result passed to method" do
        expect_no_offenses(<<~RUBY)
          class OuterAction
            include Axn
            def call
              result = InnerAction.call(param: "value")
              process_result(result)
            end
          end
        RUBY
      end

      it "accepts call! usage" do
        expect_no_offenses(<<~RUBY)
          class OuterAction
            include Axn
            def call
              InnerAction.call!(param: "value")
            end
          end
        RUBY
      end
    end

    context "with improper result handling" do
      it "reports offense when result is not checked" do
        expect_offense(<<~RUBY)
          class OuterAction
            include Axn
            def call
              InnerAction.call(param: "value")
              ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ Axn/UncheckedResult: Use `call!` or check `result.ok?` when calling Axns from within Axns
            end
          end
        RUBY
      end

      it "reports offense when result is assigned but not used" do
        expect_offense(<<~RUBY)
          class OuterAction
            include Axn
            def call
              result = InnerAction.call(param: "value")
                       ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ Axn/UncheckedResult: Use `call!` or check `result.ok?` when calling Axns from within Axns
              # result is assigned but never checked
            end
          end
        RUBY
      end

      it "reports offense when result is assigned but only used in unrelated context" do
        expect_offense(<<~RUBY)
          class OuterAction
            include Axn
            def call
              result = InnerAction.call(param: "value")
                       ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ Axn/UncheckedResult: Use `call!` or check `result.ok?` when calling Axns from within Axns
              some_other_method(result.some_other_attribute)
            end
          end
        RUBY
      end
    end
  end

  context "when not inside Axn classes" do
    it "accepts Axn calls in regular classes" do
      expect_no_offenses(<<~RUBY)
        class RegularClass
          def some_method
            InnerAction.call(param: "value")
          end
        end
      RUBY
    end

    it "accepts Axn calls in regular methods" do
      expect_no_offenses(<<~RUBY)
        class SomeClass
          include Action
          def other_method
            InnerAction.call(param: "value")
          end
        end
      RUBY
    end
  end

  context "when inside Axn classes but not in call method" do
    it "accepts Axn calls in other methods" do
      expect_no_offenses(<<~RUBY)
        class OuterAction
          include Action
          def other_method
            InnerAction.call(param: "value")
          end
        end
      RUBY
    end
  end

  context "with complex result handling patterns" do
    it "accepts early return with result check" do
      expect_no_offenses(<<~RUBY)
        class OuterAction
          include Action
          def call
            result = InnerAction.call(param: "value")
            return result unless result.ok?

            another_result = AnotherAction.call(param: "value")
            return another_result unless another_result.ok?

            # Process both successful results...
          end
        end
      RUBY
    end

    it "accepts conditional result handling" do
      expect_no_offenses(<<~RUBY)
        class OuterAction
          include Action
          def call
            result = InnerAction.call(param: "value")

            if result.ok?
              process_success(result)
            else
              handle_failure(result)
            end
          end
        end
      RUBY
    end

    it "accepts result used in multiple contexts" do
      expect_no_offenses(<<~RUBY)
        class OuterAction
          include Action
          def call
            result = InnerAction.call(param: "value")

            if result.ok?
              expose success_data: result.data
            else
              log_error(result.error)
            end

            result
          end
        end
      RUBY
    end
  end

  context "edge cases" do
    it "handles nested class definitions" do
      expect_no_offenses(<<~RUBY)
        module Actions
          class OuterAction
            include Axn
            def call
              result = InnerAction.call(param: "value")
              return result unless result.ok?
            end
          end
        end
      RUBY
    end

    it "handles anonymous classes" do
      expect_no_offenses(<<~RUBY)
        Class.new do
          include Action
          def call
            result = InnerAction.call(param: "value")
            return result unless result.ok?
          end
        end
      RUBY
    end

    it "handles method calls with complex arguments" do
      expect_no_offenses(<<~RUBY)
        class OuterAction
          include Action
          def call
            result = InnerAction.call(
              param: "value",
              another_param: "another_value"
            )
            return result unless result.ok?
          end
        end
      RUBY
    end
  end
end
