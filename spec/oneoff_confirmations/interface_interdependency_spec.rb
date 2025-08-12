# frozen_string_literal: true

# TODO: was used for manual testing -- clean up or remove when done

RSpec.describe "One-off confirmation" do
  describe "Interface interdependencies" do
    describe "default accepts proc" do
      let(:action) do
        build_action do
          expects :channel, default: -> { valid_channels.first }

          def call
            log "Got channel: #{channel}"
          end

          private

          def valid_channels = %w[web email sms].freeze
        end
      end

      subject { action.call }

      it { is_expected.to be_ok }
      it "sets the default channel value" do
        # Create an action instance to access its internal context for verification
        action_instance = action.new
        action_instance._run
        expect(action_instance.instance_variable_get("@__context").provided_data[:channel]).to eq("web")
      end
    end

    context "interdependencies to consider for future support" do
      # TODO: how to support this? necessary to have some expected values dependent on others...
      # describe "validations can reference instance methods" do
      #   let(:action) do
      #     build_action do
      #       expects :channel, inclusion: { in: :valid_channels_for_number }
      #       expects :number

      #       def call
      #         log "Got channel: #{channel}"
      #       end

      #       private

      #       VALID_CHANNELS = %w[web email sms].freeze

      #       def valid_channels_for_number
      #         return ["channel_for_1"] if number == 1

      #         VALID_CHANNELS
      #       end
      #     end
      #   end

      #   it { expect(action.call(number: 1, channel: "channel_for_1")).to be_ok }
      #   it { expect(action.call(number: 2, channel: "channel_for_1")).not_to be_ok }

      #   it { expect(action.call(number: 2, channel: "sms")).to be_ok }
      #   it { expect(action.call(number: 2, channel: "channel_for_1")).not_to be_ok }
      # end

      describe "validations can reference class methods methods" do
        let(:action) do
          build_action do
            # NOTE: only works if method already defined!
            def self.valid_channels_for_number = ["overridden_valid_channels"]

            expects :channel, inclusion: { in: valid_channels_for_number }

            def call
              log "Got channel: #{channel}"
            end
          end
        end

        it { expect(action.call(channel: "overridden_valid_channels")).to be_ok }
        it { expect(action.call(channel: "any_other_value")).not_to be_ok }
      end
    end
  end
end
