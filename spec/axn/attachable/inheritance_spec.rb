# frozen_string_literal: true

RSpec.describe Axn::Attachable do
  describe "inheritance" do
    describe "axn_method inheritance" do
      context "with helper methods" do
        let(:parent_class) do
          Class.new do
            include Axn

            axn_method :multiply, superclass: self do |value:|
              value * the_multiple
            end

            def the_multiple = 2
          end
        end

        let(:child_class) do
          Class.new(parent_class) do
            def the_multiple = 3
          end
        end

        it "can call inherited methods" do
          expect(parent_class.multiply!(value: 5)).to eq(10)
          class Child < parent_class
            def the_multiple = 3
          end
          expect(Child.multiply!(value: 5)).to eq(15)
        end
      end

      context "with anonymous classes" do
        let(:parent) do
          Class.new do
            include Axn

            axn_method :multiply do |value:|
              value * 2
            end
          end
        end

        let(:child) { Class.new(parent) }

        it "inherits axn_method definitions" do
          expect(child).to respond_to(:multiply!)
          expect(child.const_defined?(:Axns)).to be true
          expect(child.const_get(:Axns).const_defined?(:Multiply)).to be true
        end

        it "has separate _attached_axn_descriptors configurations" do
          expect(parent._attached_axn_descriptors.map(&:name)).to eq([:multiply])
          expect(child._attached_axn_descriptors.map(&:name)).to eq([:multiply])
          expect(parent._attached_axn_descriptors.object_id).not_to eq(child._attached_axn_descriptors.object_id)
        end

        it "can call inherited methods" do
          result = child.multiply!(value: 5)
          expect(result).to eq(10)
        end

        it "can call inherited axn methods" do
          multiply_axn = child.const_get(:Axns).const_get(:Multiply)
          result = multiply_axn.call(value: 5)
          expect(result).to be_ok
          expect(result.value).to eq(10)
        end
      end

      context "with named classes" do
        before do
          stub_const("ParentWithAxnableMethod", Class.new do
            include Axn

            axn_method :add do |value:|
              value + 10
            end
          end)

          stub_const("ChildWithAxnableMethod", Class.new(ParentWithAxnableMethod))
        end

        it "inherits axn_method definitions" do
          expect(ChildWithAxnableMethod).to respond_to(:add!)
          expect(ChildWithAxnableMethod.const_defined?(:Axns)).to be true
          expect(ChildWithAxnableMethod.const_get(:Axns).const_defined?(:Add)).to be true
        end

        it "has separate _attached_axn_descriptors configurations" do
          expect(ParentWithAxnableMethod._attached_axn_descriptors.map(&:name)).to eq([:add])
          expect(ChildWithAxnableMethod._attached_axn_descriptors.map(&:name)).to eq([:add])
          expect(ParentWithAxnableMethod._attached_axn_descriptors.object_id).not_to eq(ChildWithAxnableMethod._attached_axn_descriptors.object_id)
        end

        it "can call inherited methods" do
          result = ChildWithAxnableMethod.add!(value: 5)
          expect(result).to eq(15)
        end

        it "can call inherited axn methods" do
          add_axn = ChildWithAxnableMethod.const_get(:Axns).const_get(:Add)
          result = add_axn.call(value: 5)
          expect(result).to be_ok
          expect(result.value).to eq(15)
        end
      end

      context "with method overrides" do
        before do
          stub_const("ParentWithOverride", Class.new do
            include Axn

            axn_method :calculate do |value:|
              value * 2
            end
          end)

          stub_const("ChildWithOverride", Class.new(ParentWithOverride) do
            axn_method :calculate do |value:|
              value * 3
            end
          end)
        end

        it "allows child to override parent methods" do
          expect(ParentWithOverride.calculate!(value: 5)).to eq(10)
          expect(ChildWithOverride.calculate!(value: 5)).to eq(15)
        end
      end
    end

    describe "axn inheritance" do
      context "with anonymous classes" do
        let(:parent) do
          Class.new do
            include Axn

            axn :triple, expose_return_as: :value do |value:|
              value * 3
            end
          end
        end

        let(:child) { Class.new(parent) }

        it "inherits axn definitions" do
          expect(child).to respond_to(:triple)
          expect(child).to respond_to(:triple!)
          expect(child).to respond_to(:triple_async)
        end

        it "has separate _attached_axn_descriptors configurations" do
          expect(parent._attached_axn_descriptors.map(&:name)).to eq([:triple])
          expect(child._attached_axn_descriptors.map(&:name)).to eq([:triple])
          expect(parent._attached_axn_descriptors.object_id).not_to eq(child._attached_axn_descriptors.object_id)
        end

        it "can call inherited methods" do
          result = child.triple!(value: 5)
          expect(result).to be_ok
          expect(result.value).to eq(15)
        end

        it "can call inherited axn methods" do
          result = child.triple(value: 5)
          expect(result).to be_ok
          expect(result.value).to eq(15)
        end
      end

      context "with named classes" do
        let(:parent_class) do
          Class.new do
            include Axn

            axn :increment, expose_return_as: :value do |value:|
              value + 20
            end
          end
        end

        let(:child_class) { Class.new(parent_class) }

        it "inherits axn definitions" do
          expect(child_class).to respond_to(:increment)
          expect(child_class).to respond_to(:increment!)
          expect(child_class).to respond_to(:increment_async)
        end

        it "has separate _attached_axn_descriptors configurations" do
          expect(parent_class._attached_axn_descriptors.map(&:name)).to eq([:increment])
          expect(child_class._attached_axn_descriptors.map(&:name)).to eq([:increment])
          expect(parent_class._attached_axn_descriptors.object_id).not_to eq(child_class._attached_axn_descriptors.object_id)
        end

        it "can call inherited methods" do
          result = child_class.increment!(value: 5)
          expect(result).to be_ok
          expect(result.value).to eq(25)
        end

        it "can call inherited axn methods" do
          result = child_class.increment(value: 5)
          expect(result).to be_ok
          expect(result.value).to eq(25)
        end
      end

      context "with block-based axn" do
        before do
          stub_const("ParentWithBlockAxn", Class.new do
            include Axn

            axn :square, expose_return_as: :value do |value:|
              value**2
            end
          end)

          stub_const("ChildWithBlockAxn", Class.new(ParentWithBlockAxn))
        end

        it "inherits block-based axn definitions" do
          expect(ChildWithBlockAxn).to respond_to(:square)
          expect(ChildWithBlockAxn).to respond_to(:square!)
          expect(ChildWithBlockAxn).to respond_to(:square_async)
        end

        it "can call inherited methods" do
          result = ChildWithBlockAxn.square!(value: 4)
          expect(result).to be_ok
          expect(result.value).to eq(16)
        end
      end
    end

    describe "mixed inheritance" do
      before do
        stub_const("ParentWithMixed", Class.new do
          include Axn

          axn_method :method1 do |value:|
            value + 1
          end

          axn :action1, expose_return_as: :value do |value:|
            value * 2
          end
        end)

        stub_const("ChildWithMixed", Class.new(ParentWithMixed) do
          axn_method :method2 do |value:|
            value + 2
          end

          axn :action2, expose_return_as: :value do |value:|
            value * 3
          end
        end)
      end

      it "inherits both axn_method and axn definitions" do
        expect(ChildWithMixed).to respond_to(:method1!)
        expect(ChildWithMixed.const_defined?(:Axns)).to be true
        expect(ChildWithMixed.const_get(:Axns).const_defined?(:Method1)).to be true
        expect(ChildWithMixed).to respond_to(:action1, :action1!, :action1_async)
        expect(ChildWithMixed).to respond_to(:method2!)
        expect(ChildWithMixed.const_get(:Axns).const_defined?(:Method2)).to be true
        expect(ChildWithMixed).to respond_to(:action2, :action2!, :action2_async)
      end

      it "has separate configurations for both types" do
        expect(ParentWithMixed._attached_axn_descriptors.map(&:name)).to eq(%i[method1 action1])
        expect(ChildWithMixed._attached_axn_descriptors.map(&:name)).to eq(%i[method1 action1 method2 action2])
        expect(ParentWithMixed._attached_axn_descriptors.object_id).not_to eq(ChildWithMixed._attached_axn_descriptors.object_id)
      end

      it "can call all inherited methods" do
        expect(ChildWithMixed.method1!(value: 5)).to eq(6)
        result1 = ChildWithMixed.action1!(value: 5)
        expect(result1).to be_ok
        expect(result1.value).to eq(10)
        expect(ChildWithMixed.method2!(value: 5)).to eq(7)
        result2 = ChildWithMixed.action2!(value: 5)
        expect(result2).to be_ok
        expect(result2.value).to eq(15)
      end
    end

    describe "recursion prevention" do
      it "prevents infinite recursion during factory creation" do
        expect do
          Class.new do
            include Axn

            axn_method :test do |value:|
              value * 2
            end
          end
        end.not_to raise_error
      end

      it "prevents infinite recursion with inheritance" do
        expect do
          parent = Class.new do
            include Axn

            axn_method :test do |value:|
              value * 2
            end
          end

          Class.new(parent)
        end.not_to raise_error
      end
    end
  end
end
