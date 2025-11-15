# frozen_string_literal: true

# rubocop:disable Naming/MethodParameterName, Lint/ConstantDefinitionInBlock
RSpec.describe Axn::Core::Memoization do
  let(:test_action) { build_axn }

  describe ".memo" do
    context "when memo_wise is not available" do
      before do
        # Ensure memo_wise is not loaded
        hide_const("MemoWise") if defined?(MemoWise)
      end

      context "with methods without arguments" do
        it "memoizes the method result" do
          action_class = build_axn do
            memo def num = rand(10)
          end

          instance = action_class.allocate
          instance.send(:initialize)
          first_result = instance.num
          expect(instance.num).to eq(first_result)
          expect(instance.num).to eq(first_result)
        end

        it "works with multi-line method definitions" do
          action_class = build_axn do
            memo def num
              rand(10)
            end
          end

          instance = action_class.allocate
          instance.send(:initialize)
          first_result = instance.num
          expect(instance.num).to eq(first_result)
        end
      end

      context "with methods that have arguments" do
        it "raises an error suggesting memo_wise" do
          expect do
            Class.new do
              include Axn

              memo def num(x) = x * 2
            end
          end.to raise_error(
            ArgumentError,
            /Memoization of methods with arguments requires the 'memo_wise' gem/,
          )
        end

        it "raises an error for keyword arguments" do
          expect do
            Class.new do
              include Axn

              memo def num(x:) = x * 2
            end
          end.to raise_error(
            ArgumentError,
            /Memoization of methods with arguments requires the 'memo_wise' gem/,
          )
        end
      end
    end

    context "when memo_wise is available" do
      let(:memo_wise_module) do
        Module.new do
          def self.prepended(base)
            base.extend(ClassMethods)
          end

          module ClassMethods
            def memo_wise(method_name)
              # Mock memo_wise behavior - actually implement memoization
              original_method = instance_method(method_name)

              define_method(method_name) do |*args, **kwargs, &block|
                # Create a valid cache key for instance variable name
                cache_key = [method_name, args, kwargs].hash.abs
                ivar = :"@_memo_wise_#{method_name}_#{cache_key}"

                if instance_variable_defined?(ivar)
                  instance_variable_get(ivar)
                else
                  value = original_method.bind(self).call(*args, **kwargs, &block)
                  instance_variable_set(ivar, value)
                end
              end
            end
          end
        end
      end

      before do
        stub_const("MemoWise", memo_wise_module)
      end

      it "delegates to memo_wise for methods without arguments" do
        action_class = build_axn do
          memo def num = rand(10)
        end

        instance = action_class.allocate
        instance.send(:initialize)
        first_result = instance.num
        expect(instance.num).to eq(first_result)
        expect(instance.num).to eq(first_result)
      end

      it "allows memoizing methods with positional arguments" do
        action_class = build_axn do
          memo def multiply(x, y) = x * y
        end

        instance = action_class.allocate
        instance.send(:initialize)

        # First call computes and caches
        result1 = instance.multiply(5, 3)
        expect(result1).to eq(15)

        # Subsequent calls with same args return cached value
        result2 = instance.multiply(5, 3)
        expect(result2).to eq(15)
        expect(result2).to eq(result1)

        # Different args compute new value
        result3 = instance.multiply(2, 4)
        expect(result3).to eq(8)
        expect(result3).not_to eq(result1)
      end

      it "allows memoizing methods with keyword arguments" do
        action_class = build_axn do
          memo def calculate(x:, y:) = x * y
        end

        instance = action_class.allocate
        instance.send(:initialize)

        # First call computes and caches
        result1 = instance.calculate(x: 5, y: 3)
        expect(result1).to eq(15)

        # Subsequent calls with same kwargs return cached value
        result2 = instance.calculate(x: 5, y: 3)
        expect(result2).to eq(15)
        expect(result2).to eq(result1)

        # Different kwargs compute new value
        result3 = instance.calculate(x: 2, y: 4)
        expect(result3).to eq(8)
        expect(result3).not_to eq(result1)
      end

      it "allows memoizing methods with mixed arguments" do
        action_class = build_axn do
          memo def compute(x, y:, z: 1) = x * y * z
        end

        instance = action_class.allocate
        instance.send(:initialize)

        # First call computes and caches
        result1 = instance.compute(2, y: 3)
        expect(result1).to eq(6)

        # Subsequent calls with same args return cached value
        result2 = instance.compute(2, y: 3)
        expect(result2).to eq(6)
        expect(result2).to eq(result1)

        # Different args compute new value
        result3 = instance.compute(2, y: 3, z: 2)
        expect(result3).to eq(12)
        expect(result3).not_to eq(result1)
      end

      it "allows memoizing methods with blocks" do
        action_class = build_axn do
          @call_count = 0

          memo def with_block(x, &block)
            @call_count = (@call_count || 0) + 1
            block.call(x)
          end
        end

        instance = action_class.allocate
        instance.send(:initialize)

        # First call executes block and caches
        result1 = instance.with_block(5) { |n| n * 2 }
        expect(result1).to eq(10)
        expect(instance.instance_variable_get(:@call_count)).to eq(1)

        # Subsequent calls with same args return cached value (block not executed)
        result2 = instance.with_block(5) { |n| n * 3 }
        expect(result2).to eq(10) # Still returns cached value from first call
        expect(instance.instance_variable_get(:@call_count)).to eq(1) # Method not called again
      end
    end
  end
end
# rubocop:enable Naming/MethodParameterName, Lint/ConstantDefinitionInBlock
