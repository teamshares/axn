# frozen_string_literal: true

RSpec.describe Action do
  let(:action) do
    build_action do
      gets :foo, type: Numeric, numericality: { greater_than: 10 }
      gets :ssn, sensitive: true

      sets :bar
      sets :phone, sensitive: true
      sets :the_internal_context, sensitive: true

      def call
        set :bar, foo * 10
        set :phone, "123-456-7890"
        set :the_internal_context, internal_context
        fail! "intentional error" if foo == 13
      end
    end
  end

  let(:foo) { 11 }
  let(:result) { action.call(foo:, ssn: "abc") }

  context "inbound facade #inspect" do
    subject { result.the_internal_context.inspect }

    it { is_expected.to eq "#<Action::InternalContext foo: 11, ssn: [FILTERED]>" }
  end

  context "outbound facade #inspect" do
    subject { result.inspect }

    context "when OK" do
      it {
        is_expected.to eq "#<Action::Result [OK] bar: 110, phone: [FILTERED], the_internal_context: [FILTERED]>"
      }
    end

    context "when exception" do
      let(:foo) { 9 }

      it {
        is_expected.to eq "#<Action::Result [failed with Action::InboundValidationError: 'Foo must be greater than 10'] bar: nil, phone: nil, the_internal_context: nil>" # rubocop:disable Metrics/LineLength
      }
    end

    context "when failed" do
      let(:foo) { 13 }

      it {
        is_expected.to eq "#<Action::Result [failed with 'intentional error'] bar: 130, phone: [FILTERED], the_internal_context: [FILTERED]>"
      }
    end
  end
end
