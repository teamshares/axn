# frozen_string_literal: true

require_relative "../../support/shared_examples/axn_attached_to_behavior"

RSpec.describe Axn do
  describe ".axn_method" do
    let(:client) do
      build_axn do
        error "bad"

        axn_method :number, error: "badbadbad" do |arg:|
          fail! "arg was all 1s" if arg.to_s.chars.uniq == ["1"]
          raise "arg was all 2s" if arg.to_s.chars.uniq == ["2"]

          10 + arg.to_i
        end
      end
    end

    it "exposes expected API" do
      expect(client).not_to respond_to(:number)
      expect(client).to respond_to(:number!)
      expect(client).to respond_to(:number_axn)
    end

    describe "when called as axn" do
      it "handles success" do
        result = client.number_axn(arg: 123)
        expect(result).to be_ok
        expect(result.value).to eq(133)
      end

      it "handles fail!" do
        result = client.number_axn(arg: 111)
        expect(result).not_to be_ok
        expect(result.error).to eq("arg was all 1s")
        expect(result.exception).to be_a(Axn::Failure)
        expect(result.exception.message).to eq("arg was all 1s")
        expect(result.value).to eq(nil)
      end

      it "handles raise" do
        result = client.number_axn(arg: 22)
        expect(result).not_to be_ok
        expect(result.error).to eq("badbadbad")
        expect(result.exception).to be_a(RuntimeError)
        expect(result.value).to eq(nil)
      end
    end

    describe "when called as method" do
      it "handles success" do
        result = client.number!(arg: 123)
        expect(result).to eq(133)
      end

      it "handles fail!" do
        expect { client.number!(arg: 111) }.to raise_error(Axn::Failure) do |error|
          expect(error.message).to eq("arg was all 1s")
        end
      end

      it "handles raise" do
        expect { client.number!(arg: 22) }.to raise_error(RuntimeError) do |error|
          expect(error.message).to eq("arg was all 2s")
        end
      end
    end

    describe "return value behavior" do
      it "returns the block's value directly, not wrapped in Axn::Result" do
        result = client.number!(arg: 123)
        expect(result).to be_a(Integer)
        expect(result).to eq(133)
        expect(result).not_to be_a(Axn::Result)
      end

      it "returns different types directly" do
        string_client = build_axn do
          axn_method :greeting do |name:|
            "Hello, #{name}!"
          end
        end

        result = string_client.greeting!(name: "World")
        expect(result).to be_a(String)
        expect(result).to eq("Hello, World!")
        expect(result).not_to be_a(Axn::Result)
      end

      it "returns complex objects directly" do
        hash_client = build_axn do
          axn_method :user_data do |id:|
            { id:, name: "User #{id}", active: true }
          end
        end

        result = hash_client.user_data!(id: 42)
        expect(result).to be_a(Hash)
        expect(result).to eq({ id: 42, name: "User 42", active: true })
        expect(result).not_to be_a(Axn::Result)
      end

      it "returns nil directly when block returns nil" do
        nil_client = build_axn do
          axn_method :nothing do
            nil
          end
        end

        result = nil_client.nothing!
        expect(result).to be_nil
        expect(result).not_to be_a(Axn::Result)
      end

      it "returns false directly when block returns false" do
        false_client = build_axn do
          axn_method :is_false do
            false
          end
        end

        result = false_client.is_false!
        expect(result).to be(false)
        expect(result).not_to be_a(Axn::Result)
      end

      it "returns arrays directly" do
        array_client = build_axn do
          axn_method :list do |items:|
            items.map(&:upcase)
          end
        end

        result = array_client.list!(items: %w[a b c])
        expect(result).to be_an(Array)
        expect(result).to eq(%w[A B C])
        expect(result).not_to be_a(Axn::Result)
      end
    end

    describe "custom expose_return_as" do
      it "uses custom expose_return_as field" do
        custom_client = build_axn do
          axn_method :custom, expose_return_as: :data do |value:|
            "processed: #{value}"
          end
        end

        result = custom_client.custom!(value: "test")
        expect(result).to eq("processed: test")
        expect(result).not_to be_a(Axn::Result)
      end
    end

    describe "comparison with regular axn" do
      it "shows the difference between axn and axn_method return values" do
        comparison_client = build_axn do
          axn :regular_axn, expose_return_as: :value do |x:|
            x * 2
          end

          axn_method :method_axn do |x:|
            x * 2
          end
        end

        # Regular axn returns Axn::Result
        regular_result = comparison_client.regular_axn(x: 5)
        expect(regular_result).to be_a(Axn::Result)
        expect(regular_result.value).to eq(10)

        # axn_method returns the value directly
        method_result = comparison_client.method_axn!(x: 5)
        expect(method_result).to eq(10)
        expect(method_result).not_to be_a(Axn::Result)
      end
    end

    describe "inheritance behavior" do
      let(:parent_class) do
        Class.new do
          include Axn::Attachable
          include Axn::Core::Flow

          axn_method :parent_method do |value:|
            "parent: #{value}"
          end
        end
      end

      let(:child_class) do
        Class.new(parent_class) do
          axn_method :child_method do |value:|
            "child: #{value}"
          end
        end
      end

      it "inherits axn_method definitions and returns values directly" do
        # Both should work and return values directly (axn_method creates class methods)
        parent_result = parent_class.parent_method!(value: "test")
        expect(parent_result).to eq("parent: test")
        expect(parent_result).not_to be_a(Axn::Result)

        child_result = child_class.parent_method!(value: "test")
        expect(child_result).to eq("parent: test")
        expect(child_result).not_to be_a(Axn::Result)

        child_only_result = child_class.child_method!(value: "test")
        expect(child_only_result).to eq("child: test")
        expect(child_only_result).not_to be_a(Axn::Result)
      end
    end

    describe "error handling with direct returns" do
      it "raises errors immediately when using the ! method" do
        error_client = build_axn do
          axn_method :error_method do
            fail! "Something went wrong"
          end
        end

        expect { error_client.error_method! }.to raise_error(Axn::Failure) do |error|
          expect(error.message).to eq("Something went wrong")
        end
      end

      it "raises exceptions immediately when using the ! method" do
        exception_client = build_axn do
          axn_method :exception_method do
            raise "Runtime error"
          end
        end

        expect { exception_client.exception_method! }.to raise_error(RuntimeError) do |error|
          expect(error.message).to eq("Runtime error")
        end
      end
    end

    describe "edge cases" do
      it "handles empty blocks" do
        empty_client = build_axn do
          axn_method :empty do
            # Empty block
          end
        end

        result = empty_client.empty!
        expect(result).to be_nil
        expect(result).not_to be_a(Axn::Result)
      end

      it "handles blocks that return symbols" do
        symbol_client = build_axn do
          axn_method :symbol_method do
            :success
          end
        end

        result = symbol_client.symbol_method!
        expect(result).to eq(:success)
        expect(result).not_to be_a(Axn::Result)
      end
    end

    describe "with existing axn classes" do
      it "works with existing axn class that has single exposed field" do
        single_exposure_axn = Axn::Factory.build(exposes: [:value]) do |value:|
          expose :value, value * 2
        end

        client = build_axn do
          axn_method :single, axn_klass: single_exposure_axn
        end

        result = client.single!(value: 5)
        expect(result).to eq(10)
        expect(result).not_to be_a(Axn::Result)
      end

      it "works with existing axn class that has no exposed fields" do
        no_exposure_axn = Axn::Factory.build do |value:|
          value * 2
        end

        client = build_axn do
          axn_method :none, axn_klass: no_exposure_axn
        end

        result = client.none!(value: 5)
        expect(result).to be_a(Axn::Result)
        expect(result).to be_ok
      end

      it "raises error with existing axn class that has multiple exposed fields" do
        multiple_exposure_axn = Axn::Factory.build(exposes: %i[value extra]) do |value:|
          expose :value, value * 2
          expose :extra, "processed"
        end

        expect do
          build_axn do
            axn_method :multiple, axn_klass: multiple_exposure_axn
          end
        end.to raise_error(Axn::Attachable::AttachmentError,
                           /Cannot determine expose_return_as for existing axn class with multiple exposed fields: value, extra/)
      end

      it "still works with fresh blocks even when existing axn classes are problematic" do
        client = build_axn do
          axn_method :fresh, expose_return_as: :data do |value:|
            "fresh: #{value * 2}"
          end
        end

        result = client.fresh!(value: 5)
        expect(result).to eq("fresh: 10")
        expect(result).not_to be_a(Axn::Result)
      end
    end

    describe "class naming and namespacing" do
      it "creates SomeClass::Axns::Foo from axn_method(:foo)" do
        # Create the class first, then define the constant
        some_class = Class.new do
          include Axn

          axn_method :foo do
            123
          end
        end

        # Set the constant after the class is created
        stub_const("SomeClass", some_class)

        # The axn_method should create a class in the Axns namespace
        expect(SomeClass.const_defined?(:Axns)).to be true

        attached_axns = SomeClass.const_get(:Axns)
        expect(attached_axns.const_defined?(:Foo)).to be true

        foo_class = attached_axns.const_get(:Foo)
        expect(foo_class.name).to eq("SomeClass::Axns::Foo")

        # Verify the class works as expected by calling the method on the client
        result = SomeClass.foo!
        expect(result).to eq(123)
      end
    end

    describe "name collision handling" do
      it "raises AttachmentError when trying to define both axn and axn_method with the same name (axn first)" do
        expect do
          Class.new do
            include Axn

            axn(:foo) do
              1
            end

            axn_method(:foo) do
              2
            end
          end
        end.to raise_error(Axn::Attachable::AttachmentError, /Method unable to attach -- method 'foo!' is already taken/)
      end

      it "raises AttachmentError when trying to define both axn_method and axn with the same name (axn_method first)" do
        expect do
          Class.new do
            include Axn

            axn_method(:foo) do
              1
            end

            axn(:foo) do
              2
            end
          end
        end.to raise_error(Axn::Attachable::AttachmentError, /Axn unable to attach -- method 'foo!' is already taken/)
      end

      it "allows child class to override parent's axn_method with the same name" do
        parent_class = Class.new do
          include Axn

          axn_method :foo do
            "parent"
          end
        end

        child_class = Class.new(parent_class) do
          axn_method :foo do
            "child"
          end
        end

        # Parent should still work with its original implementation
        expect(parent_class.foo!).to eq("parent")

        # Child should use its overridden implementation
        expect(child_class.foo!).to eq("child")

        # Both should have the constant defined in their Axns namespace
        expect(parent_class.const_get(:Axns).const_defined?(:Foo)).to be true
        expect(child_class.const_get(:Axns).const_defined?(:Foo)).to be true
      end
    end

    describe "superclass option" do
      let(:base_client_class) do
        Class.new do
          include Axn

          def self.name
            "TestClient"
          end

          def test_method
            "test_method_result"
          end
        end
      end

      context "with explicit superclass" do
        let(:client_class) do
          Class.new(base_client_class) do
            # Create a superclass that provides the test_method
            test_superclass = Class.new do
              def test_method
                "test_method_result"
              end
            end

            axn_method :test, superclass: test_superclass do
              # Now has access to test_method through superclass
              test_method
            end
          end
        end

        it "inherits from explicit superclass" do
          axn_class = client_class.const_get(:Axns).const_get(:Test)
          expect(axn_class.superclass).to be_a(Class)
          expect(axn_class.superclass.instance_methods).to include(:test_method)
        end

        it "has access to client methods through superclass" do
          result = client_class.test!
          expect(result).to eq("test_method_result")
        end
      end

      context "with superclass: Object" do
        let(:client_class) do
          Class.new(base_client_class) do
            axn_method :test, superclass: Object do
              # This should inherit from Object and NOT have access to client methods
              "standalone_result"
            end
          end
        end

        it "inherits from Object" do
          axn_class = client_class.const_get(:Axns).const_get(:Test)
          expect(axn_class.superclass).to eq(Object)
        end

        it "does not have access to client methods" do
          result = client_class.test!
          expect(result).to eq("standalone_result")
        end

        it "cannot call client methods from within the axn" do
          client_class.axn_method :test_with_client_call, superclass: Object do
            test_method # This should raise an error
          end

          expect { client_class.test_with_client_call! }.to raise_error(NameError, /undefined local variable or method `test_method'/)
        end
      end

      context "with step strategy and superclass: Object" do
        let(:client_class) do
          Class.new(base_client_class) do
            step :test_step, superclass: Object do
              # Simple step that doesn't expose anything
              "standalone_step_result"
            end
          end
        end

        it "inherits from Object" do
          axn_class = client_class.const_get(:Axns).const_get(:TestStep)
          expect(axn_class.superclass).to eq(Object)
        end

        it "works as a standalone step" do
          client = client_class.new
          client.call
          # The step runs without error (we can't easily test the result without exposing)
          expect(client.instance_variable_get(:@__context)).to be_present
        end
      end

      context "with axn strategy and superclass: Object" do
        let(:client_class) do
          Class.new(base_client_class) do
            axn :test_axn, superclass: Object do
              "standalone_axn_result"
            end
          end
        end

        it "inherits from Object" do
          axn_class = client_class.const_get(:Axns).const_get(:TestAxn)
          expect(axn_class.superclass).to eq(Object)
        end

        it "works as a standalone axn" do
          result = client_class.test_axn
          expect(result).to be_ok
        end
      end
    end

    describe "module inclusion options" do
      describe "include parameter" do
        context "with single module" do
          before do
            stub_const("HelperModule", Module.new do
              def helper_method
                "helper_result"
              end

              def url_builder(uuid:)
                "https://api.example.com/#{uuid}"
              end
            end)
          end

          let(:client_class) do
            Class.new do
              include Axn

              axn_method :test_action, include: HelperModule do
                helper_method
              end
            end
          end

          it "includes the module in the axn class" do
            axn_class = client_class.const_get(:Axns).const_get(:TestAction)
            expect(axn_class.included_modules).to include(HelperModule)
          end

          it "makes module methods available in the axn block" do
            result = client_class.test_action!
            expect(result).to eq("helper_result")
          end

          it "provides access to axn_attached_to from included methods" do
            client_class_with_attached = Class.new do
              include Axn

              def self.name
                "TestClient"
              end

              axn_method :test_action, include: HelperModule do
                url_builder(uuid: "123")
              end
            end

            result = client_class_with_attached.test_action!
            expect(result).to eq("https://api.example.com/123")
          end
        end

        context "with multiple modules" do
          before do
            stub_const("HelperModule1", Module.new do
              def method_1
                "from_module_1"
              end
            end)

            stub_const("HelperModule2", Module.new do
              def method_2
                "from_module_2"
              end
            end)
          end

          let(:client_class) do
            Class.new do
              include Axn

              axn_method :test_action, include: [HelperModule1, HelperModule2] do
                "#{method_1}_#{method_2}"
              end
            end
          end

          it "includes all modules in the axn class" do
            axn_class = client_class.const_get(:Axns).const_get(:TestAction)
            expect(axn_class.included_modules).to include(HelperModule1)
            expect(axn_class.included_modules).to include(HelperModule2)
          end

          it "makes all module methods available in the axn block" do
            result = client_class.test_action!
            expect(result).to eq("from_module_1_from_module_2")
          end
        end

        context "with empty array" do
          let(:client_class) do
            Class.new do
              include Axn

              axn_method :test_action, include: [] do
                "no_modules"
              end
            end
          end

          it "works without any modules" do
            result = client_class.test_action!
            expect(result).to eq("no_modules")
          end
        end
      end

      describe "extend parameter" do
        context "with single module" do
          before do
            stub_const("ExtenderModule", Module.new do
              def extended_method
                "extended_result"
              end
            end)
          end

          let(:client_class) do
            Class.new do
              include Axn

              axn_method :test_action, extend: ExtenderModule do
                extended_method
              end
            end
          end

          it "extends the axn class with the module" do
            axn_class = client_class.const_get(:Axns).const_get(:TestAction)
            expect(axn_class.singleton_class.included_modules).to include(ExtenderModule)
          end

          it "makes extended methods available as class methods on the axn class" do
            axn_class = client_class.const_get(:Axns).const_get(:TestAction)
            expect(axn_class.extended_method).to eq("extended_result")
          end
        end

        context "with multiple modules" do
          before do
            stub_const("ExtenderModule1", Module.new do
              def extended_method_1
                "extended_1"
              end
            end)

            stub_const("ExtenderModule2", Module.new do
              def extended_method_2
                "extended_2"
              end
            end)
          end

          let(:client_class) do
            Class.new do
              include Axn

              axn_method :test_action, extend: [ExtenderModule1, ExtenderModule2] do
                "#{extended_method_1}_#{extended_method_2}"
              end
            end
          end

          it "extends the axn class with all modules" do
            axn_class = client_class.const_get(:Axns).const_get(:TestAction)
            expect(axn_class.singleton_class.included_modules).to include(ExtenderModule1)
            expect(axn_class.singleton_class.included_modules).to include(ExtenderModule2)
          end

          it "makes all extended methods available as class methods on the axn class" do
            axn_class = client_class.const_get(:Axns).const_get(:TestAction)
            expect(axn_class.extended_method_1).to eq("extended_1")
            expect(axn_class.extended_method_2).to eq("extended_2")
          end
        end
      end

      describe "prepend parameter" do
        context "with single module" do
          before do
            stub_const("PrependerModule", Module.new do
              def prepended_method
                "prepended_result"
              end
            end)
          end

          let(:client_class) do
            Class.new do
              include Axn

              axn_method :test_action, prepend: PrependerModule do
                prepended_method
              end
            end
          end

          it "prepends the module to the axn class" do
            axn_class = client_class.const_get(:Axns).const_get(:TestAction)
            expect(axn_class.included_modules).to include(PrependerModule)
            # Prepend puts the module first in the ancestor chain
            expect(axn_class.included_modules.first).to eq(PrependerModule)
          end

          it "makes prepended methods available in the axn block" do
            result = client_class.test_action!
            expect(result).to eq("prepended_result")
          end
        end

        context "with multiple modules" do
          before do
            stub_const("PrependerModule1", Module.new do
              def prepended_method_1
                "prepended_1"
              end
            end)

            stub_const("PrependerModule2", Module.new do
              def prepended_method_2
                "prepended_2"
              end
            end)
          end

          let(:client_class) do
            Class.new do
              include Axn

              axn_method :test_action, prepend: [PrependerModule1, PrependerModule2] do
                "#{prepended_method_1}_#{prepended_method_2}"
              end
            end
          end

          it "prepends all modules to the axn class" do
            axn_class = client_class.const_get(:Axns).const_get(:TestAction)
            expect(axn_class.included_modules).to include(PrependerModule1)
            expect(axn_class.included_modules).to include(PrependerModule2)
            # Last prepended module should be first in the chain (prepend adds to front)
            expect(axn_class.included_modules.first).to eq(PrependerModule2)
          end

          it "makes all prepended methods available in the axn block" do
            result = client_class.test_action!
            expect(result).to eq("prepended_1_prepended_2")
          end
        end
      end

      describe "combined module options" do
        before do
          stub_const("IncludeModule", Module.new do
            def included_method
              "included"
            end
          end)

          stub_const("ExtendModule", Module.new do
            def extended_method
              "extended"
            end
          end)

          stub_const("PrependModule", Module.new do
            def prepended_method
              "prepended"
            end
          end)
        end

        let(:client_class) do
          Class.new do
            include Axn

            axn_method :test_action, include: IncludeModule, extend: ExtendModule, prepend: PrependModule do
              "#{prepended_method}_#{included_method}"
            end
          end
        end

        it "applies all module options to the axn class" do
          axn_class = client_class.const_get(:Axns).const_get(:TestAction)

          # Check include
          expect(axn_class.included_modules).to include(IncludeModule)

          # Check extend
          expect(axn_class.singleton_class.included_modules).to include(ExtendModule)

          # Check prepend (should be first in the chain)
          expect(axn_class.included_modules).to include(PrependModule)
          expect(axn_class.included_modules.first).to eq(PrependModule)
        end

        it "makes included and prepended methods available in the axn block" do
          result = client_class.test_action!
          expect(result).to eq("prepended_included")
        end

        it "makes extended methods available as class methods on the axn class" do
          axn_class = client_class.const_get(:Axns).const_get(:TestAction)
          expect(axn_class.extended_method).to eq("extended")
        end
      end

      describe "module method precedence" do
        before do
          stub_const("BaseModule", Module.new do
            def conflicting_method
              "base_module"
            end
          end)

          stub_const("PrependModule", Module.new do
            def conflicting_method
              "prepend_module"
            end
          end)

          stub_const("IncludeModule", Module.new do
            def conflicting_method
              "include_module"
            end
          end)
        end

        context "with prepend and include having conflicting methods" do
          let(:client_class) do
            Class.new do
              include Axn

              axn_method :test_action, include: [BaseModule, IncludeModule], prepend: PrependModule do
                conflicting_method
              end
            end
          end

          it "prepend takes precedence over include" do
            result = client_class.test_action!
            expect(result).to eq("prepend_module")
          end
        end
      end

      describe "real-world usage pattern" do
        before do
          require "json"

          stub_const("ApiHelpers", Module.new do
            def url_builder(resource:, uuid:)
              "https://api.example.com/#{resource}/#{uuid}"
            end

            def parse_response(response)
              JSON.parse(response)
            end

            def build_resource_name
              axn_attached_to.name.demodulize.downcase
            end
          end)
        end

        let(:client_class) do
          Class.new do
            include Axn

            def self.name
              "UserService"
            end

            axn_method :get_user, include: ApiHelpers do |uuid:|
              url = url_builder(resource: build_resource_name, uuid:)
              # Simulate API call
              response = '{"id": 123, "name": "John Doe"}'
              parse_response(response)
            end
          end
        end

        it "demonstrates real-world usage with include parameter" do
          result = client_class.get_user!(uuid: "123")
          expect(result).to eq({ "id" => 123, "name" => "John Doe" })
        end

        it "shows that axn_attached_to is available in included modules" do
          # This test verifies that the included module can access the attached class
          result = client_class.get_user!(uuid: "456")
          expect(result).to eq({ "id" => 123, "name" => "John Doe" })
        end
      end
    end

    describe "axn_attached_to" do
      include_examples "axn_attached_to behavior", :axn_method
    end
  end
end
