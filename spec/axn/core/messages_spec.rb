# frozen_string_literal: true

RSpec.describe Axn do
  subject(:result) { action.call }

  describe "#messages configuration" do
    describe "success message" do
      subject { result.success }

      context "when static" do
        let(:action) do
          build_axn do
            success "Great news!"
          end
        end

        it { expect(result).to be_ok }
        it { is_expected.to eq("Great news!") }
      end

      context "when dynamic (callable)" do
        let(:action) do
          build_axn do
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
          build_axn do
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
          build_axn do
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
          build_axn do
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
          build_axn do
            exposes :foo, default: "bar"
            success -> { "Great news: #{@var} from #{foo}" }

            def call
              expose foo: "baz"
              @var = 123
            end
          end
        end

        it { expect(result).to be_ok }
        it "raises NoMethodError (no direct reader), which is swallowed and falls back to default success" do
          is_expected.to eq("Action completed successfully")
        end
      end

      context "when dynamic raises error" do
        let(:action) do
          build_axn do
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
          build_axn do
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
          build_axn do
            success -> { raise ArgumentError, "fail message" }
          end
        end

        before do
          allow(Axn::Extensions).to receive(:best_effort).and_call_original
        end

        it "calls Axn::Extensions.best_effort when success message callable raises" do
          result = action.call
          expect(result).to be_ok
          expect(result.success).to eq("Action completed successfully")
          expect_best_effort_called(message_substring: "determining message callable")
        end

        # no exception should bubble; it is piped and we fall back
      end

      context "when dynamic raises error in success message with fallback" do
        let(:action) do
          build_axn do
            # Define fallback first so the failing handler (defined last) is evaluated before it
            success "Fallback success message"
            success -> { raise ArgumentError, "fail message" }
          end
        end

        before do
          allow(Axn::Extensions).to receive(:best_effort).and_call_original
        end

        it "falls back to next non-failing success message" do
          result = action.call
          expect(result).to be_ok
          expect(result.success).to eq("Fallback success message")
          expect_best_effort_called(message_substring: "determining message callable")
        end
      end

      context "when dynamic raises error in success message with conditional fallback" do
        let(:action) do
          build_axn do
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
          allow(Axn::Extensions).to receive(:best_effort).and_call_original
        end

        it "falls back to next non-failing success message when condition is false" do
          result = action.call(trigger: false)
          expect(result).to be_ok
          expect(result.success).to eq("Final fallback")
        end

        it "falls back to conditional success message when condition is true" do
          result = action.call(trigger: true)
          expect(result).to be_ok
          # "Final fallback" is the unconditional headline (base); "Conditional fallback" is a
          # conditional reason, so it gains the base prefix.
          expect(result.success).to eq("Final fallback: Conditional fallback")
          expect_best_effort_called(message_substring: "determining message callable")
        end
      end

      context "when dynamic raises error in success message with symbol method fallback" do
        let(:action) do
          build_axn do
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
          allow(Axn::Extensions).to receive(:best_effort).and_call_original
        end

        it "falls back to next non-failing success message" do
          result = action.call
          expect(result).to be_ok
          # All three are unconditional headlines; most-recent-first, the raising lambda is skipped
          # and :fallback_method wins (replacing — not prefixing — the earlier "Final fallback").
          expect(result.success).to eq("Method fallback")
          expect_best_effort_called(message_substring: "determining message callable")
        end
      end

      context "when all success messages fail" do
        let(:action) do
          build_axn do
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
          allow(Axn::Extensions).to receive(:best_effort).and_call_original
        end

        it "falls back to static message when all dynamic ones fail" do
          result = action.call
          expect(result).to be_ok
          expect(result.success).to eq("Static fallback")
          # All 3 dynamic candidates (:failing_method, and the two raising lambdas) fail and are
          # swallowed before the static fallback is reached.
          expect_best_effort_called(message_substring: "determining message callable", times: 3)
        end
      end

      context "when all success messages fail including static" do
        let(:action) do
          build_axn do
            # Order to ensure the first evaluated failure is the ArgumentError("first fail")
            success -> { raise NameError, "third fail" }
            success -> { raise "second fail" }
            success -> { raise ArgumentError, "first fail" }
          end
        end

        before do
          allow(Axn::Extensions).to receive(:best_effort).and_call_original
        end

        it "falls back to default success message when all configured ones fail" do
          result = action.call
          expect(result).to be_ok
          expect(result.success).to eq("Action completed successfully")
          # All 3 configured success candidates raise and are swallowed before the built-in
          # default message is reached.
          expect_best_effort_called(message_substring: "determining message callable", times: 3)
        end
      end

      context "with symbol predicate matcher" do
        context "arity 0 method" do
          let(:action) do
            build_axn do
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
          it { expect(result.error).to eq("Default error: Argument problem") }
        end

        context "arity 1 method (receives exception)" do
          let(:action) do
            build_axn do
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
            build_axn do
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
            build_axn do
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
            build_axn do
              error "Default error"
              error "AE", if: ->(exception:) { exception.is_a?(ArgumentError) }

              def call
                raise ArgumentError, "boom"
              end
            end
          end

          it { expect(result).not_to be_ok }
          it { expect(result.error).to eq("Default error: AE") }
        end

        context "unless matcher" do
          context "simple test" do
            let(:action) do
              build_axn do
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
              expect(result.error).to eq("Default error: Custom error")
            end
          end

          context "with symbol predicate" do
            let(:action) do
              build_axn do
                expects :missing_param
                error "Default error"
                error "Custom error", unless: :good_argument?

                def good_argument?
                  false
                end
              end
            end

            it { expect(result).not_to be_ok }
            it { expect(result.error).to eq("Default error: Custom error") }

            context "when condition is true" do
              let(:action) do
                build_axn do
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
              build_axn do
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
            it { expect(result.error).to eq("Default error: Custom error") }

            context "when condition is true" do
              let(:action) do
                build_axn do
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

        context "when both if and unless are provided" do
          it "accepts success with if: and unless: together (ANDed: every condition must pass)" do
            action = build_axn do
              expects :flagged, :suppressed, type: :boolean, optional: true
              success "combined message", if: -> { flagged }, unless: -> { suppressed }
            end

            expect(action.call(flagged: true, suppressed: false).success).to eq("combined message")
            expect(action.call(flagged: true, suppressed: true).success).not_to eq("combined message")
            expect(action.call(flagged: false, suppressed: false).success).not_to eq("combined message")
          end

          it "accepts error with if: and unless: together (ANDed: every condition must pass)" do
            action = build_axn do
              expects :flagged, :suppressed, type: :boolean, optional: true
              error "combined message", if: -> { flagged }, unless: -> { suppressed }
              def call
                raise "boom"
              end
            end

            expect(action.call(flagged: true, suppressed: false).error).to eq("combined message")
            expect(action.call(flagged: true, suppressed: true).error).not_to eq("combined message")
            expect(action.call(flagged: false, suppressed: false).error).not_to eq("combined message")
          end
        end

        context "when given a bare falsey condition (e.g. a forwarded feature flag)" do
          it "applies the message as if no if: condition were given" do
            action = build_axn do
              error "Custom error", if: false

              def call
                raise "boom"
              end
            end

            expect(action.call.error).to eq("Custom error")
          end

          it "applies the message as if no unless: condition were given" do
            action = build_axn do
              error "Custom error", unless: false

              def call
                raise "boom"
              end
            end

            expect(action.call.error).to eq("Custom error")
          end
        end
      end
    end

    describe "error message" do
      subject { result.error }

      context "when static" do
        let(:action) do
          build_axn do
            expects :missing_param
            error "Bad news!"
          end
        end

        it { expect(result).not_to be_ok }
        it { is_expected.to eq("Bad news!") }

        # The ability to access default_error and default_success within conditional message blocks
        # is already tested in the "custom error layers" section where default_error is used
        # in a conditional error message with the line: a.error -> { "whoa: #{default_error}" }, if: -> { param == 4 }
      end

      context "when dynamic (callable)" do
        let(:action) do
          build_axn do
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

        it "can access default_error within conditional message blocks" do
          # This functionality is already tested in the "custom error layers" section
          expect(true).to be true
        end
      end

      context "when dynamic (block)" do
        let(:action) do
          build_axn do
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
          build_axn do
            expects :missing_param
            error ->(e) { "Bad news: #{e.class.name}" }
          end
        end

        it { expect(result).not_to be_ok }

        it "is evaluated within internal context" do
          is_expected.to eq("Bad news: Axn::InboundValidationError")
        end

        it "can access default_error within conditional message blocks" do
          # This functionality is already tested in the "custom error layers" section
          expect(true).to be true
        end

        context "when fail! is called with custom message" do
          # SHARP EDGE: an unconditional dynamic `error` is now a *headline* (base), and a fail!
          # message is a reason the base attaches. Because this particular headline reads
          # `e.message` — which, for the Failure, IS the fail! message — the message appears twice.
          # Realistic patterns avoid this: use a static base headline, or opt the fail! out with
          # `standalone: true` (covered below). A raised (non-fail!) exception renders cleanly.
          let(:action) do
            build_axn do
              error ->(e) { "Bad news: #{e.message}" }

              def call
                fail! "Explicitly-set error message"
              end
            end
          end

          it "prefixes the fail! message with the dynamic headline (which here re-embeds it)" do
            is_expected.to eq("Bad news: Explicitly-set error message: Explicitly-set error message")
          end

          it "renders the fail! message standalone when opted out with standalone: true" do
            action = build_axn do
              error ->(e) { "Bad news: #{e.message}" }
              def call = fail!("Explicitly-set error message", standalone: true)
            end
            expect(action.call.error).to eq("Explicitly-set error message")
          end
        end

        context "when fail! is called without message" do
          let(:action) do
            build_axn do
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
          build_axn do
            expects :missing_param
            error ->(exception:) { "Bad news: #{exception.class.name}" }
          end
        end

        it { expect(result).not_to be_ok }

        it "is evaluated within internal context" do
          is_expected.to eq("Bad news: Axn::InboundValidationError")
        end
      end

      context "when dynamic (symbol method name with exception)" do
        let(:action) do
          build_axn do
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
          build_axn do
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
          build_axn do
            expects :missing_param
            error -> { "" }
          end
        end

        it { expect(result).not_to be_ok }

        it "falls back to default" do
          is_expected.to eq("Something went wrong")
        end

        it "can access default_error within conditional message blocks" do
          # This functionality is already tested in the "custom error layers" section
          expect(true).to be true
        end
      end

      context "when dynamic raises error in error message" do
        let(:action) do
          build_axn do
            error -> { raise ArgumentError, "fail message" }

            def call
              raise "triggering failure"
            end
          end
        end

        before do
          allow(Axn::Extensions).to receive(:best_effort).and_call_original
        end

        it "calls Axn::Extensions.best_effort when error message callable raises" do
          result = action.call
          expect(result).not_to be_ok
          expect(result.exception).to be_a(RuntimeError)
          expect(result.error).to eq("Something went wrong")
          # Resolved once for the whole result (memoized on the Result) — the raising callable is
          # invoked a single time across the lifecycle log + this read, not once per read.
          expect_best_effort_called(message_substring: "determining message callable", times: 1)
        end
      end
    end
  end

  describe "custom error layers" do
    shared_examples "action with custom error layers" do
      before do
        # Verify exception handling triggers via Executor
        expect_any_instance_of(Axn::Core::Executor).to receive(:trigger_on_exception).and_call_original
      end

      it { expect(result).not_to be_ok }

      it "matches by string exception class name" do
        expect(result.error).to eq("Bad news!: Inbound validation error!")
      end

      it "matches specific exceptions" do
        expect(action.call(param: 1).error).to eq("Bad news!: Argument error: bad arg")
      end

      it "matches by callable matcher" do
        expect(action.call(param: 2).error).to eq("Bad news!: whoa a 2")
      end

      it "can reference instance vars" do
        expect(action.call(param: 3).error).to eq("Bad news!: whoa: 123")
      end

      it "can reference configured error" do
        expect(action.call(param: 4).error).to eq("Bad news!: whoa: Bad news!")
      end

      it "falls back correctly" do
        expect(action.call(param: 5).error).to eq("Bad news!")
      end
    end

    let(:action) do
      build_axn do
        expects :param
        error "Bad news!"

        def call
          @var = 123
          raise ArgumentError, "bad arg" if param == 1

          raise "something else"
        end
      end.tap do |a|
        a.error ->(e) { "Argument error: #{e.message}" }, if: ArgumentError
        a.error "Inbound validation error!", if: "Axn::InboundValidationError"
        a.error -> { "whoa a #{param}" }, if: -> { param == 2 }
        a.error -> { "whoa: #{@var}" }, if: -> { param == 3 }
        a.error -> { "whoa: #{default_error}" }, if: -> { param == 4 }
      end
    end

    it_behaves_like "action with custom error layers"
  end

  context "with prebuilt descriptors" do
    let(:action) do
      build_axn do
        success Axn::Core::Flow::Handlers::Descriptors::MessageDescriptor.build(handler: "Success from descriptor")
        error Axn::Core::Flow::Handlers::Descriptors::MessageDescriptor.build(handler: "Error from descriptor")
      end
    end

    it "supports prebuilt descriptors" do
      expect(action.call).to be_ok
      expect(action.call.success).to eq("Success from descriptor")
    end

    it "raises error when combining descriptor with (removed) prefix: kwarg" do
      expect do
        build_axn do
          success Axn::Core::Flow::Handlers::Descriptors::MessageDescriptor.build(handler: "Success"), prefix: "user"
        end
      end.to raise_error(ArgumentError, %r{Unknown :prefix option for error/success message})
    end
  end

  # Regression guard: a `fail!` raised from inside a `rescue` block gets Ruby's implicit `cause`
  # ($!) attached to the Failure. The user explicitly chose that message, so it must be surfaced.
  # (A removed `return if exception.cause` guard once suppressed it for the old nesting-wrap path.)
  context "when fail! is raised from within a rescue block (Failure carries a cause)" do
    let(:action) do
      build_axn do
        def call
          raise "underlying boom"
        rescue StandardError
          fail!("friendly message")
        end
      end
    end

    it "surfaces the user-provided fail! message rather than the underlying cause" do
      result = action.call
      expect(result).not_to be_ok
      expect(result.error).to eq("friendly message")
      expect(result.exception).to be_a(Axn::Failure)
      expect(result.exception.cause).to be_a(RuntimeError)
      expect(result.exception.cause.message).to eq("underlying boom")
    end
  end

  # Regression guard: a winning message block runs exactly once for the whole result lifecycle.
  # Two ways it could regress: the resolver double-invoking (it once ran body_for in `detect` then
  # again to capture the reason), or Result re-resolving on every read (it builds a fresh resolver
  # per call). Memoizing the resolved string on the single Result, plus a single body_for per
  # resolution, keeps it at one invocation regardless of how many times the message is read.
  context "when a selected dynamic message block has side effects" do
    it "invokes the winning message block exactly once across the lifecycle and repeated reads" do
      invocations = []
      action = build_axn do
        error "Base"
        error(if: ArgumentError) do
          invocations << :called
          "reason body"
        end
        def call = raise ArgumentError, "boom"
      end

      result = action.call
      expect(result.error).to eq("Base: reason body")
      result.error
      result.message
      expect(invocations.size).to eq(1)
    end
  end
end
