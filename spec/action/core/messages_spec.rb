# frozen_string_literal: true

RSpec.describe Action do
  describe "#messages configuration" do
    subject(:result) { action.call }

    describe "success message" do
      subject { result.success }

      context "when static" do
        let(:action) do
          build_action do
            messages(success: "Great news!")
          end
        end

        it { expect(result).to be_ok }
        it { is_expected.to eq("Great news!") }
      end

      context "when dynamic" do
        let(:action) do
          build_action do
            expects :foo, default: "bar"
            messages(success: -> { "Great news: #{@var} from #{foo}" })

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

      context "when dynamic with exposed vars" do
        let(:action) do
          build_action do
            exposes :foo, default: "bar"
            messages(success: -> { "Great news: #{@var} from #{foo}" })

            def call
              expose foo: "baz"
              @var = 123
            end
          end
        end

        it { expect(result).to be_ok }
        it "is evaluated within internal context + expected vars" do
          is_expected.to eq("Great news: 123 from baz")
        end
      end

      context "when dynamic raises error" do
        let(:action) do
          build_action do
            expects :foo, default: "bar"
            messages(success: -> { "Great news: #{@var} from #{foo} and #{some_undefined_var}" })

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
            messages(success: -> { "" })
          end
        end

        it { expect(result).to be_ok }
        it "falls back to default" do
          is_expected.to eq("Action completed successfully")
        end
      end
    end

    describe "error message" do
      subject { result.error }

      context "when static" do
        let(:action) do
          build_action do
            expects :missing_param
            messages(error: "Bad news!")
          end
        end

        it { expect(result).not_to be_ok }
        it { is_expected.to eq("Bad news!") }

        it "supports class level default_error" do
          expect(action.default_error).to eq("Bad news!")
        end
      end

      context "when dynamic" do
        let(:action) do
          build_action do
            expects :missing_param
            messages(error: -> { "Bad news: #{@var}" })

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

      context "when dynamic wants exception" do
        let(:action) do
          build_action do
            expects :missing_param
            messages(error: ->(e) { "Bad news: #{e.class.name}" })
          end
        end

        it { expect(result).not_to be_ok }

        it "is evaluated within internal context" do
          is_expected.to eq("Bad news: Action::InboundValidationError")
        end

        it "supports class level default_error" do
          expect(action.default_error).to eq("Bad news: Action::Failure")
        end
      end

      context "when dynamic returns blank" do
        let(:action) do
          build_action do
            expects :missing_param
            messages(error: -> { "" })
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
    end

    describe "with rescues" do
      context "when static" do
        let(:action) do
          build_action do
            expects :param
            messages(error: "Bad news!")
            rescues ArgumentError, ->(e) { "Argument error: #{e.message}" }
            rescues "Action::InboundValidationError" => "Inbound validation error!"
            rescues -> { param == 2 }, -> { "whoa a #{param}" }
            rescues -> { param == 3 }, -> { "whoa: #{@var}" }
            rescues -> { param == 4 }, -> { "whoa: #{default_error}" }

            def call
              @var = 123
              raise ArgumentError, "bad arg" if param == 1

              raise "something else"
            end
          end
        end

        it { expect(result).not_to be_ok }
        it { expect(result.error).to eq("Inbound validation error!") }

        it "rescues specific exceptions" do
          expect(action.call(param: 1).error).to eq("Argument error: bad arg")
        end

        it "rescues by callable matcher" do
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
    end
  end
end
