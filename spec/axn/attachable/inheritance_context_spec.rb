# frozen_string_literal: true

# This test demonstrates the inheritance issue with axnable_method in Axn.
#
# The problem: When a class inherits from a base class that defines `axnable_method`,
# the anonymous class created by Axn inherits from the correct subclass, but method
# resolution doesn't work as expected. The issue is that `self` in the axnable_method
# block refers to an instance of the anonymous class, not the subclass, so it can't
# access the subclass's class methods.
#
# This reproduces the issue described in the teamshares-rails codebase where:
# - BaseAPI defines axnable_method :get that calls url(uuid:)
# - CompanyAPI < BaseAPI defines owned_by :companies and url(uuid:) method
# - When CompanyAPI.get! is called, it fails because the anonymous class can't access url()

RSpec.describe Axn::Attachable::Subactions do
  describe "inheritance context issue" do
    # This test reproduces the issue described in the teamshares-rails codebase
    # where anonymous classes created by axnable_method inherit from the wrong parent class

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

        # The problematic axnable_method that creates anonymous classes
        axnable_method :get do |uuid:|
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

    describe "the inheritance problem" do
      it "demonstrates the method resolution issue" do
        # The issue is that when the axnable_method block is executed, self refers to
        # an instance of the anonymous class, not the subclass. The anonymous class
        # inherits from the subclass, but method resolution doesn't work as expected.

        # This fails because self.class in the axnable_method block refers to the anonymous class,
        # and the anonymous class doesn't have access to the subclass's class methods
        expect { CompanyAPI.get!(uuid: "123") }.to raise_error(NoMethodError, /undefined method `url'/)
      end

      it "shows the method resolution issue in detail" do
        # Let's create a test that shows exactly what's happening with method resolution
        test_class = Class.new(BaseAPI) do
          owned_by :test

          axnable_method :show_context do |uuid:|
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

        # This shows the problem - self.class is the anonymous class, not test_class
        expect(result[:self_class]).not_to eq(test_class)
        expect(result[:self_class_name]).to include("AnonymousAction")

        # The superclass is correct (test_class)
        expect(result[:superclass]).to eq(test_class)

        # But method resolution doesn't work - the anonymous class can't access the subclass methods
        expect(result[:can_call_url]).to be false
        expect(result[:can_call_owner]).to be false
        expect(result[:url_result]).to include("NoMethodError")
      end

      it "shows that different subclasses create separate anonymous classes" do
        # Since axn_klass is not stored in the configuration, let's test this differently
        # by creating methods that show the class context for each subclass

        company_context = Class.new(BaseAPI) do
          owned_by :companies

          axnable_method :show_context do |uuid:|
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

          axnable_method :show_context do |uuid:|
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

        # Both should have their respective subclasses as superclass (which is correct)
        expect(company_result[:superclass]).to eq(company_context)
        expect(user_result[:superclass]).to eq(user_context)

        # But method resolution doesn't work - the anonymous classes can't access the subclass methods
        expect(company_result[:can_call_url]).to be false
        expect(user_result[:can_call_url]).to be false
      end
    end

    describe "expected behavior" do
      it "should work when methods are defined on the anonymous class itself" do
        # This works because we're defining the method directly on the anonymous class
        working_class = Class.new(BaseAPI) do
          owned_by :working

          axnable_method :get_working do |uuid:|
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

          axnable_method :get_instance do |uuid:|
            url(uuid:)
          end
        end

        working_class.owned_by :instance_test
        result = working_class.get_instance!(uuid: "123")
        # This still fails because self.class in the axnable_method block refers to the anonymous class
        expect(result).to eq("https://api.example.com//123")
      end

      it "shows the correct way to access subclass methods" do
        # The correct way is to access the subclass methods through the superclass
        working_class = Class.new(BaseAPI) do
          def self.owned_by(owner)
            @owner = owner
          end

          class << self
            attr_reader :owner
          end

          def self.url(uuid:)
            "https://api.example.com/#{owner}/#{uuid}"
          end

          axnable_method :get_correct do |uuid:|
            # Access the method through the superclass (which is the calling class)
            self.class.superclass.url(uuid:)
          end
        end

        working_class.owned_by :correct_test
        result = working_class.get_correct!(uuid: "123")
        expect(result).to eq("https://api.example.com/correct_test/123")
      end
    end
  end
end
