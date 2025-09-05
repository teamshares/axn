# frozen_string_literal: true

require "spec_helper"

RSpec.describe Axn::Core::Timing do
  describe ".now" do
    it "returns a monotonic time value" do
      time1 = described_class.now
      time2 = described_class.now

      expect(time1).to be_a(Float)
      expect(time2).to be_a(Float)
      expect(time2).to be >= time1
    end
  end

  describe ".elapsed_ms" do
    it "calculates elapsed time in milliseconds" do
      start_time = described_class.now
      sleep(0.001) # Sleep for 1ms
      elapsed = described_class.elapsed_ms(start_time)

      expect(elapsed).to be_a(Float)
      expect(elapsed).to be >= 1.0
      expect(elapsed).to be < 100.0 # Should be much less than 100ms
    end

    it "rounds to 3 decimal places" do
      start_time = described_class.now
      elapsed = described_class.elapsed_ms(start_time)

      # Check that it's rounded to 3 decimal places
      decimal_places = elapsed.to_s.split(".").last&.length || 0
      expect(decimal_places).to be <= 3
    end
  end

  describe ".elapsed_seconds" do
    it "calculates elapsed time in seconds" do
      start_time = described_class.now
      sleep(0.001) # Sleep for 1ms
      elapsed = described_class.elapsed_seconds(start_time)

      expect(elapsed).to be_a(Float)
      expect(elapsed).to be >= 0.001
      expect(elapsed).to be < 0.1 # Should be much less than 100ms
    end

    it "rounds to 6 decimal places" do
      start_time = described_class.now
      elapsed = described_class.elapsed_seconds(start_time)

      # Check that it's rounded to 6 decimal places
      decimal_places = elapsed.to_s.split(".").last&.length || 0
      expect(decimal_places).to be <= 6
    end
  end

  describe "InstanceMethods#_with_timing" do
    let(:action) { build_axn }

    it "stores elapsed time in the context" do
      result = action.call
      expect(result.elapsed_time).to be_a(Float)
      expect(result.elapsed_time).to be >= 0
    end

    it "stores timing even when action fails" do
      failing_action = build_axn do
        def call
          fail! "intentional failure"
        end
      end

      result = failing_action.call
      expect(result.elapsed_time).to be_a(Float)
      expect(result.elapsed_time).to be >= 0
    end

    it "stores timing even when action raises exception" do
      exception_action = build_axn do
        def call
          raise "intentional exception"
        end
      end

      result = exception_action.call
      expect(result.elapsed_time).to be_a(Float)
      expect(result.elapsed_time).to be >= 0
    end
  end
end
