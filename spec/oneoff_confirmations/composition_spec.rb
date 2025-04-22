# frozen_string_literal: true

# TODO: was used for manual testing -- clean up or remove when done

RSpec.describe "One-off confirmation" do
  describe "Composition" do
    let(:wrapper) do
      Module.new do
        def self.included(base)
          base.class_eval do
            include Action
            expects :wrapper_thing
            before do
              log "before from wrapper"
            end
          end
        end
      end
    end

    let(:action) do
      build_action do
        expects :name, type: String
        exposes :greeting, type: String

        before do
          log "before from action"
        end

        def call
          expose greeting: "hi, #{name.upcase}"
        end
      end
    end

    subject { action.call(name: "name") }

    it { is_expected.to be_ok }
    it { expect(subject.greeting).to eq("hi, NAME") }

    context "via wrapper" do
      def build_wrapper_action(&block)
        action = Class.new.send(:include, wrapper)
        action.class_eval(&block) if block
        action
      end

      let(:action) do
        build_wrapper_action do
          expects :name, type: String
          exposes :greeting, type: String

          before do
            log "before from action"
          end

          def call
            expose greeting: "hi, #{name.upcase}"
          end
        end
      end

      subject { action.call(name: "name", wrapper_thing: 1) }

      it { is_expected.to be_ok }
      it { expect(subject.greeting).to eq("hi, NAME") }
    end
  end
end
