# frozen_string_literal: true

# The shape the PORO fixtures in `spec/` stand in for, and the reason the exemption exists at all:
# `ActiveModel::API` and `ActiveRecord::Core` each declare `#initialize` in their own method table, so every
# Rails model is an initializer-bearing mount target. Axn picks that superclass itself (`inherit:`) to carry the
# target's hooks, callbacks and async config, so refusing the inherited `#initialize` would name a class the app
# never wrote and offer two remedies it cannot apply.
RSpec.describe "mounting onto a target whose hierarchy declares #initialize" do
  describe "an ActiveModel::API class" do
    let(:target) do
      stub_const("MountedModel", Class.new do
        include ActiveModel::API
        include Axn::Mountable
      end)
    end

    # Asserted rather than assumed: it is what makes the examples below a test of the exemption rather than of a
    # hierarchy that happens to carry no initializer.
    it "inherits an #initialize the guard would otherwise refuse" do
      expect(Axn::Core::MethodShadowing.inherited_definer(target, :initialize)).to eq(ActiveModel::API)
    end

    it "runs a mounted axn" do
      target.mount_axn(:notify, exposes: [:notified]) { expose(:notified, true) }

      expect(target.notify.notified).to be(true)
    end

    it "runs a mounted method" do
      target.mount_axn_method(:label) { "labelled" }

      expect(target.label!).to eq("labelled")
    end

    it "still refuses an action class the app wrote under the same superclass" do
      action = Class.new(target) { include Axn }

      expect { action.call }.to raise_error(
        Axn::ContractViolation::UnsurrenderableInheritedMethod, /ActiveModel::API defines #initialize/
      )
    end
  end

  describe "an ActiveRecord model" do
    let(:target) do
      stub_const("MountedRecord", Class.new(ActiveRecord::Base) do
        self.table_name = "users"
        include Axn::Mountable
      end)
    end

    it "inherits an #initialize the guard would otherwise refuse" do
      expect(Axn::Core::MethodShadowing.inherited_definer(target, :initialize)).to eq(ActiveRecord::Core)
    end

    # The guard rather than a run: ActiveRecord defines its own `.new` on the model class, which the mounted
    # action inherits along with everything else, and that one hands axn's `#initialize` a positional attributes
    # hash it cannot take. Constructing a mounted action under an AR model is a separate limitation of mounting
    # onto models, above and beyond the name-ownership question this exemption settles.
    it "admits the mounted action at the guard" do
      target.mount_axn(:notify, exposes: [:notified]) { expose(:notified, true) }

      expect { Axn::Core::InstanceDeferral.assert_dispatchable_names_free!(target::Axns::Notify) }.not_to raise_error
    end

    it "still refuses an action class the app wrote under the same superclass" do
      action = Class.new(target) { include Axn }

      expect { action.call }.to raise_error(
        Axn::ContractViolation::UnsurrenderableInheritedMethod, /ActiveRecord::Core defines #initialize/
      )
    end
  end
end
