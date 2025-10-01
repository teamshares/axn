# frozen_string_literal: true

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
      it "creates SomeClass::AttachedAxns::Foo from axn_method(:foo)" do
        # Create the class first, then define the constant
        some_class = Class.new do
          include Axn

          axn_method :foo do
            123
          end
        end

        # Set the constant after the class is created
        stub_const("SomeClass", some_class)

        # The axn_method should create a class in the AttachedAxns namespace
        expect(SomeClass.const_defined?(:AttachedAxns)).to be true

        attached_axns = SomeClass.const_get(:AttachedAxns)
        expect(attached_axns.const_defined?(:Foo)).to be true

        foo_class = attached_axns.const_get(:Foo)
        expect(foo_class.name).to eq("SomeClass::AttachedAxns::Foo")

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

        # Both should have the constant defined in their AttachedAxns namespace
        expect(parent_class.const_get(:AttachedAxns).const_defined?(:Foo)).to be true
        expect(child_class.const_get(:AttachedAxns).const_defined?(:Foo)).to be true
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

      context "with default superclass (no explicit superclass)" do
        let(:client_class) do
          Class.new(base_client_class) do
            axn_method :test do
              # This should inherit from the proxy class and have access to client methods
              test_method
            end
          end
        end

        it "inherits from proxy superclass" do
          axn_class = client_class.const_get(:AttachedAxns).const_get(:Test)
          expect(axn_class.superclass).to eq(client_class.axn_superclass)
        end

        it "has access to client methods through proxy" do
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
          axn_class = client_class.const_get(:AttachedAxns).const_get(:Test)
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
          axn_class = client_class.const_get(:AttachedAxns).const_get(:TestStep)
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
          axn_class = client_class.const_get(:AttachedAxns).const_get(:TestAxn)
          expect(axn_class.superclass).to eq(Object)
        end

        it "works as a standalone axn" do
          result = client_class.test_axn
          expect(result).to be_ok
        end
      end
    end
  end
end
