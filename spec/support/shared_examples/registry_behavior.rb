# frozen_string_literal: true

RSpec.shared_examples "a registry" do
  describe ".built_in" do
    it "loads all files from the appropriate directory" do
      expect(described_class.built_in.keys).to include(*expected_built_in_keys)
      expect(described_class.built_in.values).to all(be_a(Module))
    end

    it "returns a hash with module values" do
      registry = described_class.built_in
      expect(registry).to be_a(Hash)
      expect(registry.values).to all(be_a(Module))
    end

    it "memoizes the result" do
      first_call = described_class.built_in
      second_call = described_class.built_in
      expect(first_call).to be(second_call)
    end
  end

  describe ".register" do
    let(:custom_item) { Module.new }

    it "adds an item to the list" do
      described_class.clear!
      described_class.register(:custom, custom_item)
      expect(described_class.all[:custom]).to be(custom_item)
    end

    it "allows custom items to be used" do
      described_class.clear!
      described_class.register(:custom, custom_item)
      expect(described_class.find(:custom)).to be(custom_item)
    end

    it "raises an error when registering a duplicate item by name" do
      described_class.clear!
      described_class.register(:custom, custom_item)
      expect do
        described_class.register(:custom, custom_item)
      end.to raise_error(expected_duplicate_error_class, "#{expected_item_type} custom already registered")
    end

    it "initializes items if not already done" do
      described_class.clear!
      expect(described_class).to receive(:all).and_call_original
      described_class.register(:custom, custom_item)
    end
  end

  describe ".all" do
    it "returns all registered items as a hash" do
      items = described_class.all
      expect(items).to be_a(Hash)
      expect(items.keys).to include(*expected_built_in_keys)
    end

    it "initializes items if not already done" do
      described_class.clear!
      # Clear the instance variable to force reinitialization
      described_class.instance_variable_set(:@items, nil)
      expect(described_class).to receive(:built_in).and_call_original
      described_class.all
    end
  end

  describe ".find" do
    it "finds an existing item" do
      expect(described_class.find(expected_find_key)).to be_a(Module)
    end

    it "raises error for non-existent item" do
      expect do
        described_class.find(:nonexistent)
      end.to raise_error(expected_not_found_error_class, "#{expected_item_type} 'nonexistent' not found")
    end

    it "raises error for nil name" do
      expect do
        described_class.find(nil)
      end.to raise_error(expected_not_found_error_class, "#{expected_item_type} name cannot be nil")
    end

    it "raises error for empty name" do
      expect do
        described_class.find("")
      end.to raise_error(expected_not_found_error_class, "#{expected_item_type} name cannot be empty")
    end

    it "raises error for whitespace-only name" do
      expect do
        described_class.find("   ")
      end.to raise_error(expected_not_found_error_class, "#{expected_item_type} name cannot be empty")
    end
  end

  describe ".clear!" do
    it "resets to built-in items only" do
      described_class.register(:custom, Module.new)
      described_class.clear!
      expect(described_class.all.keys).to include(*expected_built_in_keys)
      expect(described_class.all.keys).not_to include(:custom)
    end
  end
end
