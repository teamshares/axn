# frozen_string_literal: true

RSpec.describe Action do
  subject(:result) { action.call }

  describe "#messages configuration" do
    describe "success message" do
      subject { result.success }

      context "when static" do
        let(:action) do
          build_action do
            success "Great news!"
          end
        end

        it { expect(result).to be_ok }
        it { is_expected.to eq("Great news!") }
      end

      context "when dynamic (callable)" do
        let(:action) do
          build_action do
            expects :foo, default: "bar"
            success -> { "Great news: #{@var} from #{foo}" }

            def call
              @var = 123
            end
          end
        end

        it { expect(result).to be_ok }
        it "is evaluated within internal context + expected vars" do
          is_expected.to eq("Great news: 123 from bar")
        end
      end

      context "when dynamic (block)" do
        let(:action) do
          build_action do
            expects :foo, default: "bar"
            success { "Great news: #{@var} from #{foo}" }

            def call
              @var = 123
            end
          end
        end

        it { expect(result).to be_ok }
        it "evaluates the block in action context" do
          is_expected.to eq("Great news: 123 from bar")
        end
      end

      context "when dynamic (symbol method name)" do
        let(:action) do
          build_action do
            success :my_success

            def my_success
              "Great news via symbol!"
            end

            def call; end
          end
        end

        it { expect(result).to be_ok }
        it { is_expected.to eq("Great news via symbol!") }
      end

      context "when dynamic with exposed vars" do
        let(:action) do
          build_action do
            exposes :foo, default: "bar"
            success -> { "Great news: #{@var} from #{result.foo}" }

            def call
              expose foo: "baz"
              @var = 123
            end
          end
        end

        it { expect(result).to be_ok }
        it "can access exposed vars via result.field pattern" do
          is_expected.to eq("Great news: 123 from baz")
        end
      end

      context "when dynamic tries to access exposed vars directly" do
        let(:action) do
          build_action do
            exposes :foo, default: "bar"
            success -> { "Great news: #{@var} from #{foo}" }

            def call
              expose foo: "baz"
              @var = 123
            end
          end
        end

        it { expect(result).to be_ok }
        it "cannot access exposed vars directly (returns nil/empty)" do
          is_expected.to eq("Great news: 123 from ")
        end
      end

      context "when dynamic raises error" do
        let(:action) do
          build_action do
            expects :foo, default: "bar"
            success -> { "Great news: #{@var} from #{foo} and #{some_undefined_var}" }

            def call
              @var = 123
            end
          end
        end

        it { expect(result).to be_ok }
        it "falls back to default success" do
          is_expected.to eq("Action completed successfully")
        end
      end

      context "when dynamic returns blank" do
        let(:action) do
          build_action do
            success -> { "" }
          end
        end

        it { expect(result).to be_ok }
        it "falls back to default" do
          is_expected.to eq("Action completed successfully")
        end
      end

      context "when dynamic raises error in success message" do
        let(:action) do
          build_action do
            success -> { raise ArgumentError, "fail message" }
          end
        end

        before do
          allow(Axn::Util).to receive(:piping_error).and_call_original
        end

        it "calls Axn::Util.piping_error when success message callable raises" do
          result = action.call
          expect(result).to be_ok
          expect(result.success).to eq("Action completed successfully")
          expect_piping_error_called(
            message_substring: "determining message callable",
            error_class: ArgumentError,
            error_message: "fail message",
          )
        end

        # no exception should bubble; it is piped and we fall back
      end

      context "when dynamic raises error in success message with fallback" do
        let(:action) do
          build_action do
            # Define fallback first so the failing handler (defined last) is evaluated before it
            success "Fallback success message"
            success -> { raise ArgumentError, "fail message" }
          end
        end

        before do
          allow(Axn::Util).to receive(:piping_error).and_call_original
        end

        it "falls back to next non-failing success message" do
          result = action.call
          expect(result).to be_ok
          expect(result.success).to eq("Fallback success message")
          expect_piping_error_called(
            message_substring: "determining message callable",
            error_class: ArgumentError,
            error_message: "fail message",
          )
        end
      end

      context "when dynamic raises error in success message with conditional fallback" do
        let(:action) do
          build_action do
            expects :trigger, allow_blank: true, default: false
            # Static fallback (used when no conditional matches)
            success "Final fallback"
            # Conditional fallback that should run if trigger is true
            success "Conditional fallback", if: :trigger
            # Failing conditional defined last so it's evaluated first within conditional handlers
            success -> { raise ArgumentError, "fail message" }, if: :trigger
          end
        end

        before do
          allow(Axn::Util).to receive(:piping_error).and_call_original
        end

        it "falls back to next non-failing success message when condition is false" do
          result = action.call(trigger: false)
          expect(result).to be_ok
          expect(result.success).to eq("Final fallback")
        end

        it "falls back to conditional success message when condition is true" do
          result = action.call(trigger: true)
          expect(result).to be_ok
          expect(result.success).to eq("Conditional fallback")
          expect_piping_error_called(
            message_substring: "determining message callable",
            error_class: ArgumentError,
            error_message: "fail message",
          )
        end
      end

      context "when dynamic raises error in success message with symbol method fallback" do
        let(:action) do
          build_action do
            # Order to ensure failing runs first, then method, then static
            success "Final fallback"
            success :fallback_method
            success -> { raise ArgumentError, "fail message" }

            def fallback_method
              "Method fallback"
            end
          end
        end

        before do
          allow(Axn::Util).to receive(:piping_error).and_call_original
        end

        it "falls back to next non-failing success message" do
          result = action.call
          expect(result).to be_ok
          expect(result.success).to eq("Method fallback")
          expect_piping_error_called(
            message_substring: "determining message callable",
            error_class: ArgumentError,
            error_message: "fail message",
          )
        end
      end

      context "when all success messages fail" do
        let(:action) do
          build_action do
            # Order to evaluate failures first, leaving static as the last resort
            success "Static fallback"
            success :failing_method
            success -> { raise "second fail" }
            success -> { raise ArgumentError, "first fail" }

            def failing_method
              raise NameError, "method fail"
            end
          end
        end

        before do
          allow(Axn::Util).to receive(:piping_error).and_call_original
        end

        it "falls back to static message when all dynamic ones fail" do
          result = action.call
          expect(result).to be_ok
          expect(result.success).to eq("Static fallback")
          expect_piping_error_called(
            message_substring: "determining message callable",
            error_class: ArgumentError,
            error_message: "first fail",
          )
        end
      end

      context "when all success messages fail including static" do
        let(:action) do
          build_action do
            # Order to ensure the first evaluated failure is the ArgumentError("first fail")
            success -> { raise NameError, "third fail" }
            success -> { raise "second fail" }
            success -> { raise ArgumentError, "first fail" }
          end
        end

        before do
          allow(Axn::Util).to receive(:piping_error).and_call_original
        end

        it "falls back to default success message when all configured ones fail" do
          result = action.call
          expect(result).to be_ok
          expect(result.success).to eq("Action completed successfully")
          expect_piping_error_called(
            message_substring: "determining message callable",
            error_class: ArgumentError,
            error_message: "first fail",
          )
        end
      end

      context "with symbol predicate matcher" do
        context "arity 0 method" do
          let(:action) do
            build_action do
              expects :missing_param
              error "Default error"
              error "Argument problem", if: :bad_argument?

              def bad_argument?
                # local decision, no args
                true
              end
            end
          end

          it { expect(result).not_to be_ok }
          it { expect(result.error).to eq("Argument problem") }
        end

        context "arity 1 method (receives exception)" do
          let(:action) do
            build_action do
              error(if: :argument_error?) { |e| "Bad argument: #{e.message}" }

              def call
                raise ArgumentError, "too small"
              end

              def argument_error?(e)
                e.is_a?(ArgumentError)
              end
            end
          end

          it { expect(result).not_to be_ok }
          it { expect(result.error).to eq("Bad argument: too small") }
        end

        context "falls back to constant when method missing" do
          let(:action) do
            build_action do
              error "AE", if: :ArgumentError

              def call
                raise ArgumentError, "boom"
              end
            end
          end

          it { expect(result).not_to be_ok }
          it { expect(result.error).to eq("AE") }
        end

        context "keyword method (receives exception:)" do
          let(:action) do
            build_action do
              error(if: :argument_error_kw?) { |exception:| "Bad argument: #{exception.message}" }

              def call
                raise ArgumentError, "too small"
              end

              def argument_error_kw?(exception:)
                exception.is_a?(ArgumentError)
              end
            end
          end

          it { expect(result).not_to be_ok }
          it { expect(result.error).to eq("Bad argument: too small") }
        end

        context "lambda predicate with keyword" do
          let(:action) do
            build_action do
              error "Default error"
              error "AE", if: ->(exception:) { exception.is_a?(ArgumentError) }

              def call
                raise ArgumentError, "boom"
              end
            end
          end

          it { expect(result).not_to be_ok }
          it { expect(result.error).to eq("AE") }
        end

        context "unless matcher" do
          context "simple test" do
            let(:action) do
              build_action do
                expects :missing_param
                error "Default error"
                error "Custom error", unless: :should_skip?

                def call
                  # This method will be called during message selection
                end

                def should_skip?
                  false
                end
              end
            end

            it "uses custom error when condition is false" do
              expect(result.error).to eq("Custom error")
            end
          end

          context "with symbol predicate" do
            let(:action) do
              build_action do
                expects :missing_param
                error "Default error"
                error "Custom error", unless: :good_argument?

                def good_argument?
                  false
                end
              end
            end

            it { expect(result).not_to be_ok }
            it { expect(result.error).to eq("Custom error") }

            context "when condition is true" do
              let(:action) do
                build_action do
                  expects :missing_param
                  error "Default error"
                  error "Custom error", unless: :good_argument?

                  def good_argument?
                    true
                  end
                end
              end

              it { expect(result).not_to be_ok }
              it { expect(result.error).to eq("Default error") }
            end
          end

          context "with callable" do
            let(:action) do
              build_action do
                expects :missing_param
                error "Default error"
                error "Custom error", unless: :should_skip?

                def call
                  # Method will be called during message selection
                end

                def should_skip?
                  false
                end
              end
            end

            it { expect(result).not_to be_ok }
            it { expect(result.error).to eq("Custom error") }

            context "when condition is true" do
              let(:action) do
                build_action do
                  expects :missing_param
                  error "Default error"
                  error "Custom error", unless: :should_skip?

                  def call
                    # Method will be called during message selection
                  end

                  def should_skip?
                    true
                  end
                end
              end

              it { expect(result).not_to be_ok }
              it { expect(result.error).to eq("Default error") }
            end
          end
        end

        context "raises error when both if and unless provided" do
          it "raises ArgumentError for success" do
            expect do
              build_action do
                success "Great news!", if: :condition?, unless: :other_condition?
              end
            end.to raise_error(ArgumentError, /success cannot be called with both :if and :unless/)
          end

          it "raises ArgumentError for error" do
            expect do
              build_action do
                error "Bad news!", if: :condition?, unless: :other_condition?
              end
            end.to raise_error(ArgumentError, /error cannot be called with both :if and :unless/)
          end
        end
      end
    end

    describe "error message" do
      subject { result.error }

      context "when static" do
        let(:action) do
          build_action do
            expects :missing_param
            error "Bad news!"
          end
        end

        it { expect(result).not_to be_ok }
        it { is_expected.to eq("Bad news!") }

        it "supports result level default_error" do
          expect(result.default_error).to eq("Bad news!")
        end

        it "supports result level default_success" do
          success_result = build_action do
            success "Great news!"
          end.call

          expect(success_result.default_success).to eq("Great news!")
        end
      end

      context "when dynamic (callable)" do
        let(:action) do
          build_action do
            expects :missing_param
            error -> { "Bad news: #{@var}" }

            def call
              @var = 123
            end
          end
        end

        it { expect(result).not_to be_ok }

        it "is evaluated within internal context" do
          is_expected.to eq("Bad news: ")
        end

        it "supports result level default_error" do
          expect(result.default_error).to eq("Bad news: ")
        end
      end

      context "when dynamic (block)" do
        let(:action) do
          build_action do
            expects :missing_param
            error { "Bad news: #{@var}" }

            def call
              @var = 123
            end
          end
        end

        it { expect(result).not_to be_ok }

        it "is evaluated within internal context" do
          is_expected.to eq("Bad news: ")
        end
      end

      context "when dynamic wants exception" do
        let(:action) do
          build_action do
            expects :missing_param
            error ->(e) { "Bad news: #{e.class.name}" }
          end
        end

        it { expect(result).not_to be_ok }

        it "is evaluated within internal context" do
          is_expected.to eq("Bad news: Action::InboundValidationError")
        end

        it "supports result level default_error" do
          expect(result.default_error).to eq("Bad news: Action::InboundValidationError")
        end

        context "when fail! is called with custom message" do
          let(:action) do
            build_action do
              error ->(e) { "Bad news: #{e.message}" }

              def call
                fail! "Explicitly-set error message"
              end
            end
          end

          it "uses the custom message" do
            is_expected.to eq("Explicitly-set error message")
          end
        end

        context "when fail! is called without message" do
          let(:action) do
            build_action do
              error ->(e) { "Bad news: #{e.message}" }

              def call
                fail!
              end
            end
          end

          it "uses the default message" do
            is_expected.to eq("Bad news: Execution was halted")
          end
        end
      end

      context "when dynamic wants exception (keyword)" do
        let(:action) do
          build_action do
            expects :missing_param
            error ->(exception:) { "Bad news: #{exception.class.name}" }
          end
        end

        it { expect(result).not_to be_ok }

        it "is evaluated within internal context" do
          is_expected.to eq("Bad news: Action::InboundValidationError")
        end
      end

      context "when dynamic (symbol method name with exception)" do
        let(:action) do
          build_action do
            error :error_with_exception

            def call
              raise ArgumentError, "boom"
            end

            def error_with_exception(e)
              "Bad news via symbol: #{e.message}"
            end
          end
        end

        it { expect(result).not_to be_ok }
        it { is_expected.to eq("Bad news via symbol: boom") }
      end

      context "when dynamic (symbol method name with exception keyword)" do
        let(:action) do
          build_action do
            error :error_with_exception_kw

            def call
              raise ArgumentError, "boom"
            end

            def error_with_exception_kw(exception:)
              "Bad news via symbol kw: #{exception.message}"
            end
          end
        end

        it { expect(result).not_to be_ok }
        it { is_expected.to eq("Bad news via symbol kw: boom") }
      end

      context "when dynamic returns blank" do
        let(:action) do
          build_action do
            expects :missing_param
            error -> { "" }
          end
        end

        it { expect(result).not_to be_ok }

        it "falls back to default" do
          is_expected.to eq("Something went wrong")
        end

        it "supports result level default_error" do
          expect(result.default_error).to eq("Something went wrong")
        end
      end

      context "when dynamic raises error in error message" do
        let(:action) do
          build_action do
            error -> { raise ArgumentError, "fail message" }

            def call
              raise "triggering failure"
            end
          end
        end

        before do
          allow(Axn::Util).to receive(:piping_error).and_call_original
        end

        it "calls Axn::Util.piping_error when error message callable raises" do
          result = action.call
          expect(result).not_to be_ok
          expect(result.exception).to be_a(RuntimeError)
          expect(result.error).to eq("Something went wrong")
          expect_piping_error_called(
            message_substring: "determining message callable",
            error_class: ArgumentError,
            error_message: "fail message",
          )
        end
      end
    end
  end

  describe "custom error layers" do
    shared_examples "action with custom error layers" do
      before do
        expect_any_instance_of(action).to receive(:_trigger_on_exception).and_call_original
      end

      it { expect(result).not_to be_ok }

      it "matches by string exception class name" do
        expect(result.error).to eq("Inbound validation error!")
      end

      it "matches specific exceptions" do
        expect(action.call(param: 1).error).to eq("Argument error: bad arg")
      end

      it "matches by callable matcher" do
        expect(action.call(param: 2).error).to eq("whoa a 2")
      end

      it "can reference instance vars" do
        expect(action.call(param: 3).error).to eq("whoa: 123")
      end

      it "can reference configured error" do
        expect(action.call(param: 4).error).to eq("Bad news!")
      end

      it "falls back correctly" do
        expect(action.call(param: 5).error).to eq("Bad news!")
      end
    end

    let(:action) do
      build_action do
        expects :param
        error "Bad news!"

        def call
          @var = 123
          raise ArgumentError, "bad arg" if param == 1

          raise "something else"
        end
      end.tap do |a|
        a.error ->(e) { "Argument error: #{e.message}" }, if: ArgumentError
        a.error "Inbound validation error!", if: "Action::InboundValidationError"
        a.error -> { "whoa a #{param}" }, if: -> { param == 2 }
        a.error -> { "whoa: #{@var}" }, if: -> { param == 3 }
        a.error -> { "whoa: #{default_error}" }, if: -> { param == 4 }
      end
    end

    it_behaves_like "action with custom error layers"
  end
end
