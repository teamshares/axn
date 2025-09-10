# frozen_string_literal: true

RSpec.describe Axn::Validators::ModelValidator do
  describe "model validation" do
    context "top level" do
      context "when field does not end in _id" do
        let(:action) do
          build_axn do
            expects :user, model: true
          end
        end

        it "raises an error" do
          expect { action }.to raise_error(ArgumentError, "Model validation expects to be given a field ending in _id (given: user)")
        end
      end

      let(:action) do
        build_axn do
          expects :user_id, model: true
          exposes :the_user, :user_id

          def call
            expose :user_id, user_id
            expose :the_user, user
          end
        end
      end

      let(:test_model) { double("User", is_a?: true, name: "User") }

      before do
        stub_const("User", test_model)

        allow(test_model).to receive(:find_by).and_return(nil)
        allow(test_model).to receive(:find_by).with(id: 1).and_return(double("User", present?: true))
      end

      it "exposes readers" do
        result = action.call(user_id: 1)
        expect(result).to be_ok
        expect(result.the_user.inspect).to eq(test_model.inspect)
        expect(result.user_id).to eq(1)
      end

      it "validates" do
        expect(action.call(user_id: nil)).not_to be_ok
        expect(action.call(user_id: 2)).not_to be_ok
      end
    end

    context "subfield" do
      context "when field does not end in _id" do
        let(:action) do
          build_axn do
            expects :foo
            expects :user, model: true, on: :foo
          end
        end

        it "raises an error" do
          expect { action }.to raise_error(ArgumentError, "Model validation expects to be given a field ending in _id (given: user)")
        end
      end

      let(:action) do
        build_axn do
          expects :foo
          expects :user_id, model: true, on: :foo
          exposes :the_user, :user_id

          def call
            expose :user_id, foo[:user_id]
            expose :the_user, user
          end
        end
      end

      let(:test_model) { double("User", is_a?: true, name: "User") }

      before do
        stub_const("User", test_model)

        allow(test_model).to receive(:find_by).and_return(nil)
        allow(test_model).to receive(:find_by).with(id: 1).and_return(double("User", present?: true))
      end

      it "exposes readers" do
        result = action.call!(foo: { user_id: 1 })
        expect(result).to be_ok
        expect(result.the_user.inspect).to eq(test_model.inspect)
        expect(result.user_id).to eq(1)
      end

      it "validates" do
        expect(action.call(foo: { user_id: nil })).not_to be_ok
        expect(action.call(foo: { user_id: 2 })).not_to be_ok
      end

      context "using expects shortcut to set exposure of same name" do
        subject(:result) { action.call!(foo: { user_id: 1 }) }

        let(:action) do
          build_axn do
            expects :foo
            expects :user_id, model: true, on: :foo
            exposes :user, :user_id

            def call
              expose :user_id, user_id
              expose :user, user
            end
          end
        end

        # TODO: circle back to this when we tackle supporting passing user in directly for model: true
        # it "exposes readers" do
        #   pending "TODO: add support for exposing the same field name as the expects shortcut readers"
        #   expect(result).to be_ok
        #   expect(result.the_user.inspect).to eq(test_model.inspect)
        #   expect(result.user_id).to eq(1)
        # end
      end
    end
  end

  describe "model hash format" do
    let(:test_model) { double("User", is_a?: true, name: "User") }

    before do
      stub_const("User", test_model)
      allow(test_model).to receive(:find_by).with(id: 1).and_return(test_model)
      allow(test_model).to receive(:find_by).with(id: 2).and_return(nil)
      allow(test_model).to receive(:find_by).with(id: nil).and_return(nil)
      allow(test_model).to receive(:find_by).with(id: "").and_return(nil)
    end

    context "with explicit class" do
      let(:action) do
        build_axn do
          expects :user_id, model: { with: User }
          exposes :the_user, :user_id

          def call
            expose :user_id, user_id
            expose :the_user, user
          end
        end
      end

      context "when valid" do
        subject { action.call(user_id: 1) }

        it { is_expected.to be_ok }
      end

      context "when invalid" do
        subject { action.call(user_id: 2) }

        it "fails" do
          expect(subject).not_to be_ok
          expect(subject.exception).to be_a(Axn::InboundValidationError)
          expect(subject.exception.message).to eq("User not found for class User and ID 2")
        end
      end

      context "and allow_blank" do
        let(:action) do
          build_axn do
            expects :user_id, model: { with: User }, allow_blank: true
            exposes :the_user, :user_id, allow_blank: true

            def call
              expose :user_id, user_id
              expose :the_user, user
            end
          end
        end

        it "validates" do
          expect(action.call(user_id: 1)).to be_ok
          expect(action.call(user_id: nil)).to be_ok
          expect(action.call(user_id: "")).to be_ok
          expect(action.call(user_id: 2)).not_to be_ok
        end
      end

      context "and allow_nil" do
        let(:action) do
          build_axn do
            expects :user_id, model: { with: User }, allow_nil: true
            exposes :the_user, :user_id, allow_nil: true

            def call
              expose :user_id, user_id
              expose :the_user, user
            end
          end
        end

        it "validates" do
          expect(action.call(user_id: 1)).to be_ok
          expect(action.call(user_id: nil)).to be_ok
          expect(action.call(user_id: "")).not_to be_ok
          expect(action.call(user_id: 2)).not_to be_ok
        end
      end
    end
  end

  describe "Axn::Internal::Logging.piping_error integration for model validation" do
    let(:test_model) { double("User", is_a?: true, name: "User") }
    let(:action) do
      build_axn do
        expects :user_id, model: true
      end
    end

    before do
      stub_const("User", test_model)
      allow(test_model).to receive(:find_by).and_raise(ArgumentError, "fail model validation")
      allow(Axn::Internal::Logging).to receive(:piping_error).and_call_original
    end

    it "calls Axn::Internal::Logging.piping_error when model validation raises" do
      result = action.call(user_id: 1)
      expect(result.exception).to be_a(Axn::InboundValidationError)
      expect_piping_error_called(
        message_substring: "applying model validation",
        error_class: ArgumentError,
        error_message: "fail model validation",
      )
    end
  end
end
