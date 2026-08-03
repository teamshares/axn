# frozen_string_literal: true

# A VALID tool axn in a directory that config/initializers/axn_tool_validation.rb grants to the
# `:boot_check` adapter as a tool root.
#
# Deliberately unreferenced by any spec except tool_contract_validation_spec, which asserts that its contract was
# already validated by the time the spec runs — proving Rails invoked axn's setup hook AND that the hook reached
# a real, directory-resident tool. If a spec referenced this class first, autoloading it here would make that
# assertion vacuous.
#
# Kept out of app/actions/tools on purpose: that directory's SampleWidget must stay unloaded at boot so
# tools_eager_load_spec can still prove on-demand loading.
module Actions
  module BootValidated
    class ValidTool
      include Axn

      expects :widget_id, type: String
      exposes :widget_name, type: String

      def call
        expose widget_name: "widget-#{widget_id}"
      end
    end
  end
end
