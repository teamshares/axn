# frozen_string_literal: true

RSpec.describe Axn::Validators::TypeValidator do
  describe "type validation" do
    describe "standalone value format" do
      describe "boolean" do
        let(:action) do
          build_axn do
            expects :foo, type: :boolean
          end
        end

        it "validates" do
          expect(action.call(foo: true)).to be_ok
          expect(action.call(foo: false)).to be_ok

          expect(action.call(foo: nil)).not_to be_ok
          expect(action.call(foo: "")).not_to be_ok
          expect(action.call(foo: 1)).not_to be_ok
        end

        context "and allow_blank" do
          let(:action) do
            build_axn do
              expects :foo, type: :boolean, allow_blank: true
            end
          end

          it "validates" do
            expect(action.call(foo: true)).to be_ok
            expect(action.call(foo: false)).to be_ok

            expect(action.call(foo: nil)).to be_ok
            expect(action.call(foo: "")).to be_ok
            expect(action.call(foo: 1)).not_to be_ok
          end
        end

        context "and allow_nil" do
          let(:action) do
            build_axn do
              expects :foo, type: :boolean, allow_nil: true
            end
          end

          it "validates" do
            expect(action.call(foo: true)).to be_ok
            expect(action.call(foo: false)).to be_ok

            expect(action.call(foo: nil)).to be_ok
            expect(action.call(foo: 1)).not_to be_ok
            expect(action.call(foo: "")).not_to be_ok
          end
        end
      end

      describe "params" do
        let(:action) do
          build_axn do
            expects :foo, type: :params
          end
        end

        it "validates" do
          expect(action.call(foo: {})).to be_ok
          expect(action.call(foo: { key: "value" })).to be_ok

          expect(action.call(foo: nil)).not_to be_ok
          expect(action.call(foo: "")).not_to be_ok
          expect(action.call(foo: 1)).not_to be_ok
          expect(action.call(foo: [])).not_to be_ok
        end

        context "and allow_blank" do
          let(:action) do
            build_axn do
              expects :foo, type: :params, allow_blank: true
            end
          end

          it "validates" do
            expect(action.call(foo: {})).to be_ok
            expect(action.call(foo: { key: "value" })).to be_ok

            expect(action.call(foo: nil)).to be_ok
            expect(action.call(foo: "")).to be_ok
            expect(action.call(foo: 1)).not_to be_ok
            expect(action.call(foo: [])).to be_ok
          end
        end

        context "with ActionController::Parameters" do
          before do
            # Create a mock ActionController::Parameters class if not defined
            unless defined?(ActionController::Parameters)
              stub_const("ActionController::Parameters", Class.new(Hash) do
                def initialize(params = {})
                  super()
                  merge!(params)
                end
              end)
            end
          end

          it "validates ActionController::Parameters" do
            params = ActionController::Parameters.new(key: "value")
            expect(action.call(foo: params)).to be_ok
          end
        end
      end

      describe "uuid" do
        let(:action) do
          build_axn do
            expects :foo, type: :uuid
          end
        end

        it "validates" do
          expect(action.call(foo: "123e4567-e89b-12d3-a456-426614174000")).to be_ok
          expect(action.call(foo: "123e4567e89b12d3a456426614174000")).to be_ok

          expect(action.call(foo: nil)).not_to be_ok
          expect(action.call(foo: "")).not_to be_ok
          expect(action.call(foo: 1)).not_to be_ok
          expect(action.call(foo: "abcabc")).not_to be_ok
        end

        context "and allow_blank" do
          let(:action) do
            build_axn do
              expects :foo, type: :uuid, allow_blank: true
            end
          end

          it "validates" do
            expect(action.call(foo: "123e4567-e89b-12d3-a456-426614174000")).to be_ok
            expect(action.call(foo: "123e4567e89b12d3a456426614174000")).to be_ok

            expect(action.call(foo: nil)).to be_ok
            expect(action.call(foo: "")).to be_ok
            expect(action.call(foo: 1)).not_to be_ok
            expect(action.call(foo: "abcabc")).not_to be_ok
          end
        end
      end

      describe "class types" do
        let(:action) do
          build_axn do
            expects :foo, type: String
          end
        end

        it "validates" do
          expect(action.call(foo: "hello")).to be_ok

          expect(action.call(foo: nil)).not_to be_ok
          expect(action.call(foo: "")).not_to be_ok
          expect(action.call(foo: 1)).not_to be_ok
          expect(action.call(foo: [])).not_to be_ok
        end

        context "and allow_blank" do
          let(:action) do
            build_axn do
              expects :foo, type: String, allow_blank: true
            end
          end

          it "validates" do
            expect(action.call(foo: "hello")).to be_ok
            expect(action.call(foo: "")).to be_ok

            expect(action.call(foo: nil)).to be_ok
            expect(action.call(foo: 1)).not_to be_ok
            expect(action.call(foo: [])).to be_ok
          end
        end
      end

      describe "array of types" do
        let(:action) do
          build_axn do
            expects :foo, type: [String, Numeric]
          end
        end

        context "when valid" do
          subject { action.call(foo: 123) }

          it { is_expected.to be_ok }
        end

        context "when invalid" do
          subject { action.call(foo: Object.new) }

          it "fails" do
            expect(subject).not_to be_ok
            expect(subject.exception).to be_a(Axn::InboundValidationError)
            expect(subject.exception.message).to eq("Foo is not one of String, Numeric")
          end
        end

        context "when false" do
          subject { action.call(foo: false) }

          it "fails" do
            expect(subject).not_to be_ok
            expect(subject.exception).to be_a(Axn::InboundValidationError)
            expect(subject.exception.message).to eq("Foo is not one of String, Numeric and Foo can't be blank")
          end
        end

        context "and allow_blank" do
          let(:action) do
            build_axn do
              expects :foo, type: [String, Numeric], allow_blank: true
            end
          end

          it "validates" do
            expect(action.call(foo: 123)).to be_ok
            expect(action.call(foo: "hello")).to be_ok
            expect(action.call(foo: nil)).to be_ok
            expect(action.call(foo: "")).to be_ok
            expect(action.call(foo: Object.new)).not_to be_ok
          end
        end
      end
    end

    describe "hash format with with key" do
      describe "boolean" do
        let(:action) do
          build_axn do
            expects :foo, type: { with: :boolean }
          end
        end

        it "validates" do
          expect(action.call(foo: true)).to be_ok
          expect(action.call(foo: false)).to be_ok

          expect(action.call(foo: nil)).not_to be_ok
          expect(action.call(foo: "")).not_to be_ok
          expect(action.call(foo: 1)).not_to be_ok
        end

        context "with custom message" do
          let(:action) do
            build_axn do
              expects :foo, type: { with: :boolean, message: "must be true or false" }
            end
          end

          it "uses custom message" do
            result = action.call(foo: 1)
            expect(result).not_to be_ok
            expect(result.exception.message).to eq("Foo must be true or false")
          end
        end

        context "and allow_blank" do
          let(:action) do
            build_axn do
              expects :foo, type: { with: :boolean, allow_blank: true }
            end
          end

          it "validates" do
            expect(action.call(foo: true)).to be_ok
            expect(action.call(foo: false)).to be_ok
            expect(action.call(foo: nil)).to be_ok
            expect(action.call(foo: "")).to be_ok
            expect(action.call(foo: 1)).not_to be_ok
          end
        end
      end

      describe "params" do
        let(:action) do
          build_axn do
            expects :foo, type: { with: :params }
          end
        end

        it "validates" do
          expect(action.call(foo: {})).to be_ok
          expect(action.call(foo: { key: "value" })).to be_ok

          expect(action.call(foo: nil)).not_to be_ok
          expect(action.call(foo: "")).not_to be_ok
          expect(action.call(foo: 1)).not_to be_ok
          expect(action.call(foo: [])).not_to be_ok
        end

        context "and allow_blank" do
          let(:action) do
            build_axn do
              expects :foo, type: { with: :params, allow_blank: true }
            end
          end

          it "validates" do
            expect(action.call(foo: {})).to be_ok
            expect(action.call(foo: { key: "value" })).to be_ok
            expect(action.call(foo: nil)).to be_ok
            expect(action.call(foo: "")).to be_ok
            expect(action.call(foo: 1)).not_to be_ok
            expect(action.call(foo: [])).to be_ok
          end
        end
      end

      describe "class types" do
        let(:action) do
          build_axn do
            expects :foo, type: { with: String }
          end
        end

        it "validates" do
          expect(action.call(foo: "hello")).to be_ok

          expect(action.call(foo: nil)).not_to be_ok
          expect(action.call(foo: "")).not_to be_ok
          expect(action.call(foo: 1)).not_to be_ok
          expect(action.call(foo: [])).not_to be_ok
        end

        context "with custom message" do
          let(:action) do
            build_axn do
              expects :foo, type: { with: String, message: "must be a string" }
            end
          end

          it "uses custom message" do
            result = action.call(foo: 1)
            expect(result).not_to be_ok
            expect(result.exception.message).to eq("Foo must be a string")
          end
        end

        context "and allow_blank" do
          let(:action) do
            build_axn do
              expects :foo, type: { with: String }, allow_blank: true
            end
          end

          it "validates" do
            expect(action.call(foo: "hello")).to be_ok
            expect(action.call(foo: nil)).to be_ok
            expect(action.call(foo: "")).to be_ok
            expect(action.call(foo: [])).to be_ok
            expect(action.call(foo: 1)).not_to be_ok
          end
        end
      end

      describe "array of types" do
        let(:action) do
          build_axn do
            expects :foo, type: { with: [String, Numeric] }
          end
        end

        it "validates" do
          expect(action.call(foo: "hello")).to be_ok
          expect(action.call(foo: 123)).to be_ok

          expect(action.call(foo: nil)).not_to be_ok
          expect(action.call(foo: Object.new)).not_to be_ok
        end

        context "with custom message" do
          let(:action) do
            build_axn do
              expects :foo, type: { with: [String, Numeric], message: "must be string or number" }
            end
          end

          it "uses custom message" do
            result = action.call(foo: Object.new)
            expect(result).not_to be_ok
            expect(result.exception.message).to eq("Foo must be string or number")
          end
        end

        context "and allow_blank" do
          let(:action) do
            build_axn do
              expects :foo, type: { with: [String, Numeric] }, allow_blank: true
            end
          end

          it "validates" do
            expect(action.call(foo: "hello")).to be_ok
            expect(action.call(foo: 123)).to be_ok
            expect(action.call(foo: nil)).to be_ok
            expect(action.call(foo: "")).to be_ok
            expect(action.call(foo: Object.new)).not_to be_ok
          end
        end
      end
    end

    describe "boolean defaults with explicit false values" do
      context "default: false should not override explicit false" do
        let(:action) do
          build_axn do
            expects :is_retirement_age, :has_tenure, type: :boolean, default: false
            exposes :is_retirement_age, :has_tenure, type: :boolean

            def call
              expose :is_retirement_age, is_retirement_age
              expose :has_tenure, has_tenure
            end
          end
        end

        it "preserves explicit false values" do
          result = action.call(is_retirement_age: false, has_tenure: false)

          expect(result).to be_ok
          expect(result.is_retirement_age).to be false
          expect(result.has_tenure).to be false
        end

        it "applies defaults when not provided" do
          result = action.call

          expect(result).to be_ok
          expect(result.is_retirement_age).to be false
          expect(result.has_tenure).to be false
        end

        it "preserves explicit true values" do
          result = action.call(is_retirement_age: true, has_tenure: true)

          expect(result).to be_ok
          expect(result.is_retirement_age).to be true
          expect(result.has_tenure).to be true
        end
      end

      context "default: true should not override explicit false" do
        let(:action) do
          build_axn do
            expects :is_enabled, type: :boolean, default: true
            exposes :is_enabled, type: :boolean

            def call
              expose :is_enabled, is_enabled
            end
          end
        end

        it "preserves explicit false values" do
          result = action.call(is_enabled: false)

          expect(result).to be_ok
          expect(result.is_enabled).to be false
        end

        it "applies default when not provided" do
          result = action.call

          expect(result).to be_ok
          expect(result.is_enabled).to be true
        end

        it "preserves explicit true values" do
          result = action.call(is_enabled: true)

          expect(result).to be_ok
          expect(result.is_enabled).to be true
        end
      end
    end
  end
end
