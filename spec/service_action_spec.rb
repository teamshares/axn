# frozen_string_literal: true

RSpec.describe ServiceAction do
  it "has a version number" do
    expect(ServiceAction::VERSION).not_to be nil
  end

  def build_action(&block)
    action = Class.new.send(:include, ServiceAction)
    action.class_eval(&block) if block
    action
  end

  describe "inbound validation" do
    let(:action) do
      build_action do
        expects :foo, Numeric, numericality: { greater_than: 10 }
      end
    end

    context "success" do
      subject { action.call(foo: 11, bar: 5, baz: 1) }

      it { is_expected.to be_success }
    end

    context "contract failure" do
      subject { action.call(foo: 9, bar: 5, baz: 1) }

      it "fails" do
        expect(subject).to be_failure
        expect(subject.error).to eq("Something went wrong")
        expect(subject.exception).to be_a(ServiceAction::InboundContractViolation)
        expect(subject.exception.errors).to be_a(ActiveModel::Errors)
        expect(subject.exception.message).to eq("Foo must be greater than 10")
      end
    end
  end

  describe "outbound validation" do
    let(:action) do
      build_action do
        exposes :bar, Numeric, numericality: { greater_than: 10 }
        exposes :qux, Numeric

        def call
          expose :qux, 99
        end
      end
    end

    context "success" do
      subject { action.call(foo: 10, bar: 11, baz: 1) }

      it { is_expected.to be_success }

      it "exposes existing context" do
        expect(subject.bar).to eq(11)
      end

      it "exposes new values" do
        expect(subject.qux).to eq(99)
      end

      # TODO: should this be swallowed and just be_failure with an exception attached?
      it {
        expect do
          subject.foo
        end.to raise_error(ServiceAction::ContractualContextInterface::ContextFacade::ContextMethodNotAllowed)
      }
    end

    context "contract failure" do
      subject { action.call(foo: 10, bar: 9, baz: 1) }

      it "fails" do
        expect(subject).to be_failure
        expect(subject.error).to eq("Something went wrong")
        expect(subject.exception).to be_a(ServiceAction::OutboundContractViolation)
        expect(subject.exception.errors).to be_a(ActiveModel::Errors)
        expect(subject.exception.message).to eq("Bar must be greater than 10")
      end
    end

    context "setting failure" do
      subject { action.call(foo: 10, bar: 11, baz: 1) }

      let(:action) do
        build_action do
          exposes :bar, Numeric, numericality: { greater_than: 10 }

          def call
            expose :qux, 99
          end
        end
      end

      it "fails" do
        expect(subject).to be_failure
        expect(subject.error).to eq("Something went wrong")
        expect(subject.exception).to be_a(ServiceAction::InvalidExposureAttempt)
      end
    end
  end

  describe "complex validation" do
    let(:action) do
      build_action do
        expects :foo, String
        exposes :bar, String
      end
    end

    context "success" do
      subject { action.call(foo: "a", bar: "b", baz: "c") }

      it { is_expected.to be_success }
    end

    context "failure" do
      subject { action.call(foo: 1, bar: 2, baz: 3) }

      it "fails" do
        expect(subject).to be_failure
        expect(subject.error).to eq("Something went wrong")
        expect(subject.exception).to be_a(ServiceAction::InboundContractViolation)
        expect(subject.exception.errors).to be_a(ActiveModel::Errors)
        expect(subject.exception.message).to eq("Foo is not a String")
      end
    end
  end

  describe "return shape" do
    subject { action.call }

    context "when successful" do
      let(:action) { build_action {} }

      it "is ok" do
        is_expected.to be_success
      end
    end

    context "when fail! (user facing error)" do
      let(:action) do
        build_action do
          def call
            fail!("User-facing error")
          end
        end
      end

      it "is not ok" do
        is_expected.not_to be_success
        expect(subject.error).to eq("User-facing error")
        expect(subject.exception).to be_nil
      end
    end

    context "when exception raised" do
      let(:action) do
        build_action do
          def call
            raise "Some internal issue!"
          end
        end
      end

      it "is not ok" do
        expect { subject }.not_to raise_error
        is_expected.not_to be_success
        expect(subject.error).to eq("Something went wrong")
        expect(subject.exception).to be_a(RuntimeError)
        expect(subject.exception.message).to eq("Some internal issue!")
      end
    end
  end

  context "can call! with success" do
    let(:action) do
      build_action {}
    end

    it "is ok" do
      action.call!
    end
  end

  # TODO: implement this
  # context "can call! with error" do
  #   let(:action) do
  #     build_action do
  #       raise "bad thing"
  #     end
  #   end

  #   it "is ok" do
  #     # expect { action.call! }.to raise_error
  #     expect { action.call }.not_to raise_error
  #     expect(action.call).not_to be_success
  #   end
  # end
end
