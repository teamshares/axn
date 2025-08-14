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

      context "with symbol predicate matcher" do
        context "arity 0 method" do
          let(:action) do
            build_action do
              success "Great news!"
              error "Bad news!"

              error "Argument problem", if: :bad_argument?

              def call
                raise ArgumentError, "nope"
              end

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

        it "supports class level default_error" do
          expect(action.default_error).to eq("Bad news!")
        end

        it "supports class level default_success" do
          klass = build_action do
            success "Great news!"
          end

          expect(klass.default_success).to eq("Great news!")
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

        it "supports class level default_error" do
          expect(action.default_error).to eq("Bad news: ")
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

        it "supports class level default_error" do
          expect(action.default_error).to eq("Bad news: Action::Failure")
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

        it "supports class level default_error" do
          expect(action.default_error).to eq("Something went wrong")
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
        expect(action.call(param: 4).error).to eq("whoa: Bad news!")
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
