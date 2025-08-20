# frozen_string_literal: true

# Axn RuboCop Integration
# This file makes Axn's custom RuboCop cops available to downstream consumers
#
# Usage in .rubocop.yml:
# require:
#   - axn/rubocop

require_relative "../rubocop/cop/axn/unchecked_result"
