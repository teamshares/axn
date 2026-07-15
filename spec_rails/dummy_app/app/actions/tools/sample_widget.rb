# frozen_string_literal: true

# The dummy app namespaces app/actions under `Actions` (see
# config/initializers/axn.rb -> app_actions_autoload_namespace = :Actions), so this file
# defines Actions::Tools::SampleWidget under the app/actions autoload root.
# Deliberately unreferenced elsewhere so the eager-load test proves on-demand loading.
module Actions
  module Tools
    class SampleWidget
      include Axn
      tool

      def call = nil
    end
  end
end
