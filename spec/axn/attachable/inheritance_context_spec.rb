# frozen_string_literal: true

# This test demonstrates the inheritance issue with axn_method in Axn.
#
# The problem: When a class inherits from a base class that defines `axn_method`,
# the anonymous class created by Axn inherits from the correct subclass, but method
# resolution doesn't work as expected. The issue is that `self` in the axn_method
# block refers to an instance of the anonymous class, not the subclass, so it can't
# access the subclass's class methods.
#
# This reproduces the issue described in the teamshares-rails codebase where:
# - BaseAPI defines axn_method :get that calls url(uuid:)
# - CompanyAPI < BaseAPI defines owned_by :companies and url(uuid:) method
# - When CompanyAPI.get! is called, it fails because the anonymous class can't access url()

RSpec.describe Axn::Attachable do
  describe "inheritance context issue" do
    # This test reproduces the issue described in the teamshares-rails codebase
    # where anonymous classes created by axn_method inherit from the wrong parent class

    before do
      stub_const("BaseAPI", Class.new do
        include Axn

        # This method should be available to subclasses
        def self.owned_by(owner)
          @owner = owner
        end

        class << self
          attr_reader :owner
        end

        # This method should be available to subclasses
        def self.url(uuid:)
          "https://api.example.com/#{owner}/#{uuid}"
        end

        # The problematic axn_method that creates anonymous classes
        axn_method :get do |uuid:|
          # This is where the issue occurs - self.class should be the calling class,
          # but it's actually the anonymous class that inherits from BaseAPI
          url(uuid:)
        end
      end)

      stub_const("CompanyAPI", Class.new(BaseAPI) do
        owned_by :companies
      end)

      stub_const("UserAPI", Class.new(BaseAPI) do
        owned_by :users
      end)
    end

    describe "the inheritance fix" do
      it "demonstrates that method resolution now works correctly" do
        # With the inheritance fix, the axn_method block can now access subclass methods
        # through the method_missing proxy in the Axn namespace class

        # This should now work correctly
        result = CompanyAPI.get!(uuid: "123")
        expect(result).to eq("https://api.example.com/companies/123")
      end

      it "shows that method resolution now works correctly in detail" do
        # Let's create a test that shows exactly what's happening with method resolution
        test_class = Class.new(BaseAPI) do
          owned_by :test

          axn_method :show_context do |uuid:|
            {
              self_class: self.class,
              self_class_name: self.class.name,
              superclass: self.class.superclass,
              superclass_name: self.class.superclass&.name,
              can_call_url: respond_to?(:url),
              can_call_owner: respond_to?(:owner),
              # Try to call the method to see what happens
              url_result: begin
                url(uuid:)
              rescue StandardError => e
                "#{e.class.name}: #{e.message}"
              end,
            }
          end
        end

        result = test_class.show_context!(uuid: "123")

        # The self.class is still the AttachedAxns class (this is expected behavior)
        expect(result[:self_class]).not_to eq(test_class)
        expect(result[:self_class_name]).to include("::AttachedAxns::")

        # The superclass is the AttachedAxns namespace class
        expect(result[:superclass]).to eq(test_class.const_get(:AttachedAxns))

        # Method resolution now works through the method_missing proxy
        expect(result[:can_call_url]).to be true
        expect(result[:can_call_owner]).to be true
        expect(result[:url_result]).to eq("https://api.example.com/test/123")
      end

      it "shows that different subclasses create separate Axn namespaces" do
        # Each subclass should get its own Axn namespace, allowing proper inheritance

        company_context = Class.new(BaseAPI) do
          owned_by :companies

          axn_method :show_context do |uuid:|
            {
              class_name: self.class.name,
              superclass: self.class.superclass,
              can_call_url: respond_to?(:url),
              uuid:,
            }
          end
        end

        user_context = Class.new(BaseAPI) do
          owned_by :users

          axn_method :show_context do |uuid:|
            {
              class_name: self.class.name,
              superclass: self.class.superclass,
              can_call_url: respond_to?(:url),
              uuid:,
            }
          end
        end

        company_result = company_context.show_context!(uuid: "123")
        user_result = user_context.show_context!(uuid: "123")

        # Both should have their respective AttachedAxns namespaces as superclass
        expect(company_result[:superclass]).to eq(company_context.const_get(:AttachedAxns))
        expect(user_result[:superclass]).to eq(user_context.const_get(:AttachedAxns))

        # Method resolution now works - the Axn classes can access the subclass methods
        expect(company_result[:can_call_url]).to be true
        expect(user_result[:can_call_url]).to be true
      end
    end

    describe "expected behavior" do
      it "should work when methods are defined on the anonymous class itself" do
        # This works because we're defining the method directly on the anonymous class
        working_class = Class.new(BaseAPI) do
          owned_by :working

          axn_method :get_working do |uuid:|
            # This works because we're calling a method that exists on the anonymous class
            "https://api.example.com/working/#{uuid}"
          end
        end

        result = working_class.get_working!(uuid: "123")
        expect(result).to eq("https://api.example.com/working/123")
      end

      it "shows how the issue could be worked around" do
        # One workaround is to use instance methods instead of class methods
        # because instance methods are available through the inheritance chain
        working_class = Class.new(BaseAPI) do
          def self.owned_by(owner)
            @owner = owner
          end

          class << self
            attr_reader :owner
          end

          # Define as instance method instead of class method
          def url(uuid:)
            "https://api.example.com/#{self.class.owner}/#{uuid}"
          end

          axn_method :get_instance do |uuid:|
            url(uuid:)
          end
        end

        working_class.owned_by :instance_test
        result = working_class.get_instance!(uuid: "123")
        expect(result).to eq("https://api.example.com/instance_test/123")
      end

      it "shows that inheritance now works automatically" do
        # With the fix, inheritance works automatically through the method_missing proxy
        working_class = Class.new(BaseAPI) do
          owned_by :correct_test

          axn_method :get_correct do |uuid:|
            # Can now call methods directly - no need to access through superclass
            url(uuid:)
          end
        end

        result = working_class.get_correct!(uuid: "123")
        expect(result).to eq("https://api.example.com/correct_test/123")
      end
    end
  end
end
