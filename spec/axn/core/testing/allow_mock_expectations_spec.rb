# frozen_string_literal: true

RSpec.describe "Testing Action" do
  describe "allow_mock_expectations" do
    context "with a mock" do
      subject(:result) { action.call!(sym:) }

      let(:action) { build_axn { expects :sym, type: Symbol } }

      context "with a symbol" do
        let(:sym) { :hello }

        it { is_expected.to be_ok }
      end

      context "with an RSpec double" do
        let(:sym) { double(to_s: "hello") }

        before do
          allow_any_instance_of(Axn::Configuration).to receive(:env).and_return(
            ActiveSupport::StringInquirer.new(env),
          )
        end

        context "in test mode" do
          let(:env) { "test" }

          it "double is allowed" do
            is_expected.to be_ok
          end
        end

        context "in development mode" do
          let(:env) { "development" }

          it { expect { subject }.to raise_error(Axn::InboundValidationError) }
        end

        context "in production mode" do
          let(:env) { "production" }

          it { expect { subject }.to raise_error(Axn::InboundValidationError) }
        end
      end
    end
  end
end
