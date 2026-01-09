# frozen_string_literal: true

require_relative "../../support/shared_examples/__axn_mounted_to__behavior"

RSpec.describe Axn do
  describe ".axn" do
    let(:client) do
      build_axn
    end

    context "with existing action class" do
      let(:subaction) do
        build_axn { log "in subaction" }
      end

      it "attaches subaction" do
        expect(client).not_to respond_to(:foo)
        client.mount_axn :foo, subaction
        expect(client).to respond_to(:foo)

        expect_any_instance_of(subaction).to receive(:call).and_call_original
        expect(client.foo).to be_ok
      end
    end

    context "with existing with bare callable" do
      let(:subaction) do
        ->(expected:, arg:) { log "got expected=#{expected}, arg=#{arg}" }
      end

      it "attaches subaction" do
        expect(client).not_to respond_to(:foo)
        client.mount_axn :foo, &subaction
        expect(client).to respond_to(:foo)

        expect(client.foo).not_to be_ok

        # The automatic logging will log before and after execution, so we need to expect multiple calls
        expect(Axn.config.logger).to receive(:info).with(/About to execute with: {expected: true, arg: 123}/).ordered
        expect(Axn.config.logger).to receive(:info).with(/got expected=true, arg=123/).ordered
        expect(Axn.config.logger).to receive(:info).with(/Execution completed \(with outcome: success\)/).ordered
        expect(client.foo(expected: true, arg: 123)).to be_ok
      end

      context "with kwargs with defaults" do
        let(:subaction) do
          ->(expected:, arg: "abc") {}
        end

        it "fails to attach" do
          expect(client).not_to respond_to(:foo)
          expect { client.mount_axn(:foo, &subaction) }.to raise_error(ArgumentError, /callable expects keyword arguments with defaults/)
        end
      end
    end

    describe "defined from block with default return" do
      before do
        client.mount_axn(:foo, expose_return_as: :barfoo, &subaction)
      end

      context "can handle default exposure" do
        let(:subaction) do
          ->(char:, length:) { char * length }
        end

        it "exposes automatically" do
          expect(client).to respond_to(:foo)
          result = client.foo(char: "a", length: 5)
          expect(result).to be_a(Axn::Result)
          expect(result.barfoo).to eq("aaaaa")
        end
      end

      context "can handle early return via next" do
        let(:subaction) do
          lambda do |char:, length:|
            next "it's an A" if char == "a"

            char * length
          end
        end

        it "exposes automatically" do
          result = client.foo(char: "a", length: 5)
          expect(result.barfoo).to eq("it's an A")
        end
      end
    end

    describe "defined from block with custom exposures" do
      before do
        client.mount_axn(:foo, exposes: [:msg], &subaction)
      end

      let(:subaction) do
        lambda do |char:, length:|
          expose :msg, char * length
        end
      end

      it "handles explicit exposure" do
        result = client.foo(char: "a", length: 5)
        expect(result).to be_a(Axn::Result)
        expect(result.msg).to eq("aaaaa")
        expect { result.value }.to raise_error(NoMethodError) # Not set if there's an explicit exposure
      end
    end

    describe "handles custom expectations" do
      before do
        client.mount_axn(:foo, expects:, &subaction)
      end

      let(:expects) { [:name] }
      let(:subaction) do
        lambda do |name:|
          log "Hello #{name}"
        end
      end

      it "handles explicit exposure" do
        expect(client.foo(name: "name")).to be_ok
        expect(client.foo(name: 123)).to be_ok
        expect(client.foo).not_to be_ok
      end

      context "with custom validations" do
        let(:expects) do
          { name: { type: String } }
        end

        it "handles explicit exposure" do
          expect(client.foo(name: "name")).to be_ok
          expect(client.foo(name: 123)).not_to be_ok
        end
      end
    end

    context "with Client class customization" do
      before do
        # Create a superclass that provides the awesome_thing method
        awesome_class = Class.new do
          def self.awesome_thing = 123
        end

        client.mount_axn(:foo, exposes: :resp, superclass: awesome_class, &subaction)
      end

      let(:client) do
        build_axn do
          def self.awesome_thing = 123
        end
      end

      let(:subaction) do
        lambda do
          expose :resp, "Hello #{self.class.awesome_thing}"
        end
      end

      it "inherits from Client class" do
        expect(client.foo).to be_ok
        expect(client.foo.resp).to eq("Hello 123")
      end
    end

    describe "async method generation" do
      shared_examples "creates _async method" do
        it "creates _async method" do
          expect(client).to respond_to(:foo_async)
        end
      end

      shared_examples "raises NotImplementedError by default" do |args = {}|
        it "raises NotImplementedError by default (async disabled)" do
          expect { client.foo_async(**args) }.to raise_error(NotImplementedError, /Async execution is explicitly disabled/)
        end
      end

      context "with existing action class" do
        let(:subaction) { build_axn { log "in subaction" } }

        before { client.mount_axn :foo, subaction }

        include_examples "creates _async method"

        it "calls call_async on the subaction class" do
          allow(subaction).to receive(:call_async).with(expected: true, arg: 123)
          expect(subaction).to receive(:call_async).with(expected: true, arg: 123)
          client.foo_async(expected: true, arg: 123)
        end
      end

      context "with callable blocks" do
        context "bare callable" do
          let(:subaction) { ->(expected:, arg:) { log "got expected=#{expected}, arg=#{arg}" } }
          before { client.mount_axn :foo, &subaction }
          include_examples "creates _async method"
          include_examples "raises NotImplementedError by default", { expected: true, arg: 123 }
        end

        context "with custom exposures" do
          let(:subaction) { ->(char:, length:) { expose :msg, char * length } }
          before { client.mount_axn(:foo, exposes: [:msg], &subaction) }
          include_examples "creates _async method"
          include_examples "raises NotImplementedError by default", { char: "a", length: 5 }
        end

        context "with custom expectations" do
          let(:subaction) { ->(name:) { log "Hello #{name}" } }
          before { client.mount_axn(:foo, expects: [:name], &subaction) }
          include_examples "creates _async method"
          include_examples "raises NotImplementedError by default", { name: "World" }
        end
      end

      context "async method behavior" do
        let(:subaction) { build_axn { log "in subaction" } }
        before { client.mount_axn :foo, subaction }

        it "passes all keyword arguments to call_async and handles empty arguments" do
          allow(subaction).to receive(:call_async)

          # Test with arguments
          expect(subaction).to receive(:call_async).with(
            arg1: "value1",
            arg2: "value2",
            nested: { key: "value" },
          )
          client.foo_async(arg1: "value1", arg2: "value2", nested: { key: "value" })

          # Test with no arguments
          expect(subaction).to receive(:call_async).with(no_args)
          client.foo_async
        end

        it "raises NotImplementedError when async is disabled" do
          allow(subaction).to receive(:call_async).and_raise(NotImplementedError, "Async execution is explicitly disabled")
          expect { client.foo_async(arg: "test") }.to raise_error(NotImplementedError, "Async execution is explicitly disabled")
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

              mount_axn :test_action, include: HelperModule, exposes: [:value] do
                expose :value, helper_method
              end
            end
          end

          it "includes the module in the axn class" do
            axn_class = client_class.const_get(:Axns).const_get(:TestAction)
            expect(axn_class.included_modules).to include(HelperModule)
          end

          it "makes module methods available in the axn block" do
            result = client_class.test_action
            expect(result).to be_ok
            expect(result.value).to eq("helper_result")
          end

          it "provides access to __axn_mounted_to__ from included methods" do
            client_class_with_attached = Class.new do
              include Axn

              def self.name
                "TestClient"
              end

              mount_axn :test_action, include: HelperModule, exposes: [:value] do
                expose :value, url_builder(uuid: "123")
              end
            end

            result = client_class_with_attached.test_action
            expect(result).to be_ok
            expect(result.value).to eq("https://api.example.com/123")
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

              mount_axn :test_action, include: [HelperModule1, HelperModule2], exposes: [:value] do
                expose :value, "#{method_1}_#{method_2}"
              end
            end
          end

          it "includes all modules in the axn class" do
            axn_class = client_class.const_get(:Axns).const_get(:TestAction)
            expect(axn_class.included_modules).to include(HelperModule1)
            expect(axn_class.included_modules).to include(HelperModule2)
          end

          it "makes all module methods available in the axn block" do
            result = client_class.test_action
            expect(result).to be_ok
            expect(result.value).to eq("from_module_1_from_module_2")
          end
        end

        context "with empty array" do
          let(:client_class) do
            Class.new do
              include Axn

              mount_axn :test_action, include: [], exposes: [:value] do
                expose :value, "no_modules"
              end
            end
          end

          it "works without any modules" do
            result = client_class.test_action
            expect(result).to be_ok
            expect(result.value).to eq("no_modules")
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

              mount_axn :test_action, extend: ExtenderModule, exposes: [:value] do
                expose :value, extended_method
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

              mount_axn :test_action, extend: [ExtenderModule1, ExtenderModule2], exposes: [:value] do
                expose :value, "#{extended_method_1}_#{extended_method_2}"
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

              mount_axn :test_action, prepend: PrependerModule, exposes: [:value] do
                expose :value, prepended_method
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
            result = client_class.test_action
            expect(result).to be_ok
            expect(result.value).to eq("prepended_result")
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

              mount_axn :test_action, prepend: [PrependerModule1, PrependerModule2], exposes: [:value] do
                expose :value, "#{prepended_method_1}_#{prepended_method_2}"
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
            result = client_class.test_action
            expect(result).to be_ok
            expect(result.value).to eq("prepended_1_prepended_2")
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

            mount_axn :test_action, include: IncludeModule, extend: ExtendModule, prepend: PrependModule, exposes: [:value] do
              expose :value, "#{prepended_method}_#{included_method}"
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
          result = client_class.test_action
          expect(result).to be_ok
          expect(result.value).to eq("prepended_included")
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

              mount_axn :test_action, include: [BaseModule, IncludeModule], prepend: PrependModule, exposes: [:value] do
                expose :value, conflicting_method
              end
            end
          end

          it "prepend takes precedence over include" do
            result = client_class.test_action
            expect(result).to be_ok
            expect(result.value).to eq("prepend_module")
          end
        end
      end
    end

    describe "__axn_mounted_to__" do
      include_examples "__axn_mounted_to__ behavior", :mount_axn

      context "with inheritance" do
        let(:parent_class) do
          Class.new do
            include Axn

            def self.name
              "ParentClient"
            end

            mount_axn(:parent_action) do
              "parent result"
            end
          end
        end

        let(:child_class) do
          Class.new(parent_class) do
            def self.name
              "ChildClient"
            end

            mount_axn(:child_action) do
              "child result"
            end
          end
        end

        it "sets __axn_mounted_to__ correctly for parent actions" do
          parent_axn = parent_class.const_get(:Axns).const_get(:ParentAction)
          expect(parent_axn.__axn_mounted_to__).to eq(parent_class)
        end

        it "sets __axn_mounted_to__ correctly for child actions" do
          child_axn = child_class.const_get(:Axns).const_get(:ChildAction)
          expect(child_axn.__axn_mounted_to__).to eq(child_class)
        end

        it "inherited actions get re-attached to the child class" do
          inherited_axn = child_class.const_get(:Axns).const_get(:ParentAction)
          expect(inherited_axn.__axn_mounted_to__).to eq(child_class)
        end
      end
    end
  end
end
