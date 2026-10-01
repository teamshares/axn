# frozen_string_literal: true

require "active_support/isolated_execution_state"
require "axn/internal/reflection/property_names"

module Axn
  module Core
    module Contract
      # How a declaration-time refusal names the declaration it refuses: the direction and the field as the author
      # wrote it — `expects :company`, `exposes :total`, `expects payload.company_id` for a subfield, and
      # `shape member `sku` in expects :rows` for a member of a block-form shape.
      #
      # A refusal is raised many calls below the `expects`/`exposes` that knows the direction, through helpers that
      # are handed only the field names (and through `FieldConfig`'s and `ShapeConfig`'s constructors, which are
      # handed neither). So the label is set once, where the declaration starts, and read wherever a refusal is
      # composed — rather than threaded through every signature between the two, where a helper that forgot to
      # pass it on would silently drop the direction from every message beneath it.
      #
      # Held in `ActiveSupport::IsolatedExecutionState` (the store every per-execution value axn keeps uses), and set
      # only for the length of one declaration: a nested declaration (a block-form shape
      # member, or a class built while another is declared) restores the outer label when it finishes, raise or
      # not, and nothing outside a declaration ever sees one — so a message composed at runtime names no
      # direction rather than a stale one.
      module DeclarationLabel
        KEY = :__axn_declaration_label
        private_constant :KEY

        Label = Data.define(:text, :top)
        Entry = Data.define(:previous)
        private_constant :Label, :Entry

        class << self
          # Makes the declaration `direction` (`:expects`/`:exposes`) of `fields`, on `on:`'s route, the current
          # one, answering a token for `leave`. A pair rather than a block so `expects`/`exposes` can enter once
          # their names are canonical and leave from their own `ensure`, whatever path they return or raise by.
          def enter(direction, fields, on: nil)
            entry = Entry.new(previous: ActiveSupport::IsolatedExecutionState[KEY])
            ActiveSupport::IsolatedExecutionState[KEY] = Label.new(text: _fields_text(direction, fields, on), top: nil)
            entry
          end

          # Restores whatever was current before `enter`; a nil token (the declaration raised before entering)
          # leaves the label alone.
          def leave(entry)
            ActiveSupport::IsolatedExecutionState[KEY] = entry.previous unless entry.nil?
          end

          # Runs the block as the block-form shape member `name` of the declaration currently being judged. A
          # member is placed by the FIELD it belongs to rather than by every member between, so a member nested in
          # a member reads as one of that field's, the way the author finds it in the source.
          def declaring_member(name, &)
            top = _top
            return yield if top.nil?

            _within(Label.new(text: member(name), top:), &)
          end

          # How a shape member is named wherever a refusal is about it: `shape member `sku` in expects :rows`, or
          # the member alone outside a declaration. Read from the declaration's FIELD rather than from `current`,
          # so a refusal about one member raised while its sibling's label is current still names the right one.
          def member(name) = "shape member `#{PropertyNames.renderable_label(name)}`#{placement}"

          # `" in <field's label>"`, or nothing outside a declaration — what places a member described some other
          # way (by its class, when it has no name) in the declaration it belongs to.
          def placement = (top = _top) ? " in #{top}" : ""

          # A declared subfield config named as its declaration is (`expects payload.company_id`), for a refusal
          # about a config other than the one being declared — a re-anchored subfield, a crossed route.
          def subfield(config) = _fields_text(:expects, [config.field], config.on)

          # The current declaration's label, or nil outside a declaration.
          def current = ActiveSupport::IsolatedExecutionState[KEY]&.text

          # The label of the FIELD being declared, even while one of its members is current — for a refusal about
          # the declaration as a whole (its graph's size), wherever in it the walk was when it found out.
          def declaration = _top

          # `" on <label>"`, or `outside` (nothing, by default) outside a declaration — for a message whose subject
          # is an option rather than the field, so the sentence still reads whole where there is no declaration.
          def locator(outside = "") = (label = current) ? " on #{label}" : outside

          private

          def _within(label)
            previous = ActiveSupport::IsolatedExecutionState[KEY]
            ActiveSupport::IsolatedExecutionState[KEY] = label
            yield
          ensure
            ActiveSupport::IsolatedExecutionState[KEY] = previous
          end

          def _top
            label = ActiveSupport::IsolatedExecutionState[KEY]
            label && (label.top || label.text)
          end

          # Each name through `PropertyNames`, never its own `to_s`. A top-level field keeps its Symbol spelling
          # (`:company`); a subfield is written as the path the author's `on:` names, which is how it is found in
          # a payload (`payload.company_id`).
          def _fields_text(direction, fields, on)
            names = if on.nil?
                      fields.map { |field| PropertyNames.inspect_field_name(field) }
                    else
                      route = PropertyNames.renderable_label(on)
                      fields.map { |field| "#{route}.#{PropertyNames.renderable_label(field)}" }
                    end
            "#{direction} #{names.join(', ')}"
          end
        end

        PropertyNames = Axn::Internal::Reflection::PropertyNames
        private_constant :PropertyNames
      end
    end
  end
end
