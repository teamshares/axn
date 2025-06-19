# frozen_string_literal: true

RSpec.describe Action do
  describe "#hoist_errors with nesting" do
    subject(:result) { outer.call(subaction:, bang:, hoist:, sub_fail_or_raise:) }

    let(:subaction) do
      build_action do
        expects :sub_fail_or_raise
        messages error: "sub bad"
        def call
          raise "inner action failed" unless sub_fail_or_raise == :fail

          fail!("inner action failed")
        end
      end
    end

    let(:outer) do
      build_action do
        expects :subaction
        expects :sub_fail_or_raise
        expects :bang, allow_blank: true
        expects :hoist, allow_blank: true

        # TODO: resolve the messages-from-fail! issue, then update specs to use this
        # messages error: lambda { |e|
        #   binding.pry
        #   "outer action failed"
        # }

        def call
          if hoist
            hoist_errors(prefix: "PREFIX") { the_call }
          else
            the_call
          end
        end

        def the_call = bang ? subaction.call!(sub_fail_or_raise:) : subaction.call(sub_fail_or_raise:)
      end
    end

    context "with subaction calling fail!" do
      let(:sub_fail_or_raise) { :fail }

      context "without hoist_errors" do
        let(:hoist) { false }

        context "with bang" do
          let(:bang) { true }

          it "inner call fails parent WITHOUT custom message" do
            is_expected.not_to be_ok
            expect(result.error).to eq("Something went wrong")
            expect(result.exception).to be_nil
          end
        end

        context "without bang" do
          let(:bang) { false }

          it "inner call does not fail parent" do
            is_expected.to be_ok
          end
        end
      end

      context "with hoist_errors" do
        let(:hoist) { true }

        context "with bang" do
          let(:bang) { true }

          it "inner call fails parent" do
            is_expected.not_to be_ok
            expect(result.error).to eq("PREFIX inner action failed")
          end
        end

        context "without bang" do
          let(:bang) { false }

          it "inner call fails parent" do
            is_expected.not_to be_ok
            expect(result.error).to eq("PREFIX inner action failed")
          end
        end
      end
    end

    context "with subaction raising an exception" do
      let(:sub_fail_or_raise) { :raise }

      context "without hoist_errors" do
        let(:hoist) { false }

        context "with bang" do
          let(:bang) { true }

          it "inner call exception fails parent" do
            is_expected.not_to be_ok
            expect(result.error).to eq("Something went wrong")
            expect(result.exception).to be_a(RuntimeError)
            expect(result.exception.message).to eq("inner action failed")
          end
        end

        context "without bang" do
          let(:bang) { false }

          it "inner call does not fail parent" do
            is_expected.to be_ok
          end
        end
      end

      context "with hoist_errors" do
        let(:hoist) { true }

        context "with bang" do
          let(:bang) { true }

          it "inner call fails parent (uses parent error message parsing, but NOT child's)" do
            is_expected.not_to be_ok
            expect(result.error).not_to eq("PREFIX sub bad") # we'd get this from child error message parsing, if called WITHOUT the bang
            expect(result.error).to eq("PREFIX Something went wrong")
          end
        end

        context "without bang" do
          let(:bang) { false }

          it "inner call fails parent" do
            is_expected.not_to be_ok
            expect(result.error).to eq("PREFIX sub bad")
          end
        end
      end
    end
  end
end
