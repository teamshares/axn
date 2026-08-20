# frozen_string_literal: true

RSpec.describe Axn::Internal::ShapeGraph do
  describe ".inner_contracts" do
    subject(:positions) { described_class.inner_contracts(validations) }

    context "with no of:" do
      let(:validations) { { type: { klass: Array } } }

      it "yields nothing" do
        expect(positions).to eq([])
      end
    end

    context "with an Array's of: bag" do
      let(:validations) { { of: { klass: String, container: Array } } }

      it "yields the bag itself at the element position" do
        expect(positions).to eq([[described_class::ELEMENT_POSITION, { klass: String, container: Array }]])
      end
    end

    context "with a map's axis bag" do
      let(:validations) { { of: { keys: { klass: String }, values: { klass: Integer }, container: Hash } } }

      it "yields each axis that carries a bag" do
        expect(positions).to eq([[described_class::KEYS_POSITION, { klass: String }],
                                 [described_class::VALUES_POSITION, { klass: Integer }]])
      end
    end

    context "with a map axis naming a bare type" do
      let(:validations) { { of: { values: Integer, container: Hash } } }

      it "yields nothing for that axis, since a bare type has no inner contract" do
        expect(positions).to eq([])
      end
    end

    context "with an of: that is not a Hash" do
      let(:validations) { { of: String } }

      it "yields nothing rather than raising" do
        expect(positions).to eq([])
      end
    end
  end
end
