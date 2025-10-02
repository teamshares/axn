# frozen_string_literal: true

RSpec.shared_examples "axn_attached_to behavior" do |attachment_method|
  let(:client_class) do
    Class.new do
      include Axn

      def self.name
        "TestClient"
      end
    end
  end

  context "with axn defined from block" do
    before do
      client_class.public_send(attachment_method, :test_action) do
        "test result"
      end
    end

    it "sets axn_attached_to on the attached axn class" do
      axn_class = client_class.const_get(:Axns).const_get(:TestAction)
      expect(axn_class.axn_attached_to).to eq(client_class)
    end

    it "returns the correct class when called" do
      axn_class = client_class.const_get(:Axns).const_get(:TestAction)
      expect(axn_class.axn_attached_to.name).to eq("TestClient")
    end

    it "provides instance method axn_attached_to" do
      axn_class = client_class.const_get(:Axns).const_get(:TestAction)
      axn_instance = axn_class.new
      expect(axn_instance.axn_attached_to).to eq(client_class)
    end
  end

  context "with existing axn class" do
    let(:existing_axn) do
      build_axn do
        "existing result"
      end
    end

    before do
      if attachment_method == :axn_method
        client_class.public_send(attachment_method, :existing_action, axn_klass: existing_axn)
      else
        client_class.public_send(attachment_method, :existing_action, existing_axn)
      end
    end

    it "sets axn_attached_to on the existing axn class" do
      expect(existing_axn.axn_attached_to).to eq(client_class)
    end

    it "returns the correct class when called" do
      expect(existing_axn.axn_attached_to.name).to eq("TestClient")
    end

    it "provides instance method axn_attached_to" do
      axn_instance = existing_axn.new
      expect(axn_instance.axn_attached_to).to eq(client_class)
    end
  end
end
