# frozen_string_literal: true

RSpec.shared_examples "an async adapter interface" do |adapter_name, adapter_module, options = {}|
  describe "async :#{adapter_name} configuration" do
    it "includes the #{adapter_module} adapter module" do
      expect(action_class.ancestors).to include(adapter_module)
    end

    it "provides call_async class method" do
      expect(action_class).to respond_to(:call_async)
    end
  end

  describe "integration with Axn actions" do
    it "provides call_async method on the class" do
      expect(action_class).to respond_to(:call_async)
    end
  end

  unless options[:skip_error_handling]
    describe "error handling" do
      it "raises LoadError when #{adapter_name} is not available" do
        expect do
          build_axn do
            async adapter_name
          end
        end.to raise_error(LoadError, /#{adapter_name.to_s.capitalize} is not available/)
      end
    end
  end
end
