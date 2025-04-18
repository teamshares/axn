# frozen_string_literal: true

RSpec.shared_examples "can build Axns from callables" do
  let(:callable) do
    ->(arg:, expected:) { log "got expected=#{expected}, arg=#{arg}" }
  end

  it "builds an Axn from a callable" do
    expect(Axn::Factory).to receive(:build).and_call_original
    expect(callable).to be_a(Proc)
    expect(axn < Action).to eq(true)
    expect(axn.call(expected: true, arg: 123)).to be_ok
    expect(axn.call).not_to be_ok
  end
end

RSpec.describe Axn::Factory do
  subject(:axn) { Axn::Factory.build(**kwargs, &callable) }
  let(:kwargs) { {} }

  it_behaves_like "can build Axns from callables"
end

RSpec.describe "Axn()" do
  subject(:axn) { Axn(callable, **kwargs) }
  let(:kwargs) { {} }

  it_behaves_like "can build Axns from callables"

  context "when already Axn" do
    let(:callable) { build_action { log "in action" } }

    it "returns the Axn" do
      expect(Axn::Factory).not_to receive(:build)

      expect(callable < Action).to eq(true)
      expect(axn < Action).to eq(true)
      expect(axn.call).to be_ok
    end
  end
end
