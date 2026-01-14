# frozen_string_literal: true

RSpec.describe "Axn::Mountable superclass and inherit conflict validation" do
  describe "mount_axn" do
    it "raises error when both superclass and non-default inherit are specified" do
      expect do
        Class.new do
          include Axn

          mount_axn :test, superclass: Object, inherit: :none do
            def call
              "test"
            end
          end
        end
      end.to raise_error(Axn::Mountable::MountingError, /cannot specify both 'superclass:' and 'inherit:' options/)
    end

    it "allows superclass with default inherit (:lifecycle)" do
      expect do
        Class.new do
          include Axn

          mount_axn :test, superclass: Object, inherit: :lifecycle do
            def call
              "test"
            end
          end
        end
      end.not_to raise_error
    end

    it "allows superclass without explicit inherit (uses default)" do
      expect do
        Class.new do
          include Axn

          mount_axn :test, superclass: Object do
            def call
              "test"
            end
          end
        end
      end.not_to raise_error
    end
  end

  describe "step" do
    it "raises error when both superclass and non-default inherit are specified" do
      expect do
        Class.new do
          include Axn

          step :test, superclass: Object, inherit: :lifecycle do
            def call
              "test"
            end
          end
        end
      end.to raise_error(Axn::Mountable::MountingError, /cannot specify both 'superclass:' and 'inherit:' options/)
    end

    it "allows superclass with default inherit (:none)" do
      expect do
        Class.new do
          include Axn

          step :test, superclass: Object, inherit: :none do
            def call
              "test"
            end
          end
        end
      end.not_to raise_error
    end
  end

  describe "mount_axn_method" do
    it "raises error when both superclass and non-default inherit are specified" do
      expect do
        Class.new do
          include Axn

          mount_axn_method :test, superclass: Object, inherit: :async_only do
            "test"
          end
        end
      end.to raise_error(Axn::Mountable::MountingError, /cannot specify both 'superclass:' and 'inherit:' options/)
    end

    it "allows superclass with default inherit (:lifecycle)" do
      expect do
        Class.new do
          include Axn

          mount_axn_method :test, superclass: Object, inherit: :lifecycle do
            "test"
          end
        end
      end.not_to raise_error
    end
  end

  # NOTE: enqueues_each does not support superclass/inherit options - it always uses :async_only
end
