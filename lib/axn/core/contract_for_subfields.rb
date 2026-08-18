# frozen_string_literal: true

require "axn/core/validation/fields"
require "axn/internal/coercion"
require "axn/internal/resolved_subfields"
require "axn/internal/reflection/schema"
require "axn/core/contract/subfield_contradictions"

module Axn
  module Core
    module ContractForSubfields
      # The per-class cache slot for the resolved-subfield artifact: the config arrays it was built
      # from plus the built value. Validity is decided by comparing the arrays' IDENTITY, never the
      # value — see ClassMethods#_resolved_subfields.
      ResolvedSubfieldsCacheEntry = Data.define(:fields, :subfields, :value)

      def self.included(base)
        base.class_eval do
          # Copy-on-write, frozen at every assignment (see Contract's stores).
          class_attribute :subfield_configs, instance_accessor: false, default: [].freeze

          extend ClassMethods
        end
      end

      # Resolves the parent value a subfield config is read from — CANONICALLY: through the DEEPEST
      # reader-bearing ancestor on the chain up to the `on:` target (`public_send` of that reader —
      # memoized, model-resolving, alias-aware), then raw Extract digs for any remaining implicit
      # segments. Both spellings of the same wire path (`on: :b` and `on: "a.b"`) therefore resolve
      # identically: if `:b` is a declared subfield, its reader supplies the value either way (for a
      # `model:` subfield, the resolved record). Shared by the subfield readers and the inbound
      # validation runner so all consumers agree. An ambient config isn't indexed (its parent
      # resolves per-invocation), so it falls back to the reader-plus-digs recipe on its `on:` string.
      # Malformed hops read as absent via FieldResolvers.extract_or_nil (one doctrine: the bad
      # value's own validation classifies it, PRO-2857).
      def self.resolve_parent(action, config)
        path = action.class._resolved_subfields.index[config]
        return _resolve_parent_by_recipe(action, config.on, permit_method_call: config.method_call) if path.nil?

        # A top-level field is the depth-0 case: its parent IS the raw provided_data hash (no ancestor
        # chain to walk). Reading its leaf from here applies coerce/preprocess/default on the read path
        # without ever writing back — the same non-materializing model the deeper subfields use.
        return action.instance_variable_get(:@__context).provided_data if path.ancestors.empty?

        reader_index = deepest_reader_index(path)
        return _resolve_parent_by_recipe(action, config.on, permit_method_call: config.method_call) if reader_index.nil?

        value = _read_deepest_reader(action, config, path, reader_index)
        (reader_index...path.parent_index).each do |i|
          # Every hop below the deepest reader is an IMPLICIT intermediate (a declared node bears a
          # reader, so it would be the reader public_sent above — never dig-crossed here). So the
          # resolving config's `method_call:` governs the whole dig uniformly: `method_call: true`
          # permits dispatch across every implicit hop on this expectation's path (PRO-2926).
          value = Axn::Core::FieldResolvers.extract_or_nil(field: path.ancestors[i].last.to_s, provided_data: value,
                                                           permit_method_call: config.method_call)
        end
        value
      end

      # The chain index of the deepest reader-bearing ancestor at-or-before the `on:` target — the
      # node resolve_parent public_sends; the hops AFTER it are the ones the runtime actually digs.
      # Shared with the unanswerable-segment declaration check (SubfieldContradictions) so the two
      # can't disagree about which segments are dig-read. Nil when no ancestor bears a reader (the
      # recipe fallback path).
      def self.deepest_reader_index(path)
        (0..path.parent_index).select { |i| _reader_config(path.ancestors[i].first) }.max
      end

      # The chain index of the config's `on:` ANCHOR — the node the `on:` ROOT names. Each dotted segment
      # below that root is one more hop, so the anchor sits that many hops above the `on:` TARGET.
      def self.anchor_index(config, path)
        path.parent_index - (config.on.to_s.split(".").size - 1)
      end

      # True when the reader-bearing ancestor at `reader_index` is NOT the config's `on:` anchor — the one
      # comparison both `crossed_node` and `_deepest_reader_name` judge, kept to one seam so they can't drift
      # on what counts as an unnamed crossing (a second derivation is the failure mode this repo has been
      # bitten by before).
      def self.crosses?(config, path, reader_index)
        reader_index != anchor_index(config, path)
      end

      # The node this config resolves its parent THROUGH without naming it — its deepest reader-bearing
      # ancestor, when that ancestor is not the `on:` anchor. Only a dotted tail can put a reader-bearing
      # node between the anchor and the `on:` target: the anchor's own node always bears a reader, and no
      # ancestor above it can exceed its index. So nil means the config NAMED the reader it reads through
      # (`on: :b2`, `on: "b2.deeper"`) and that node's config order cannot affect it. Nil too for a
      # top-level config (no ancestors to walk).
      #
      # `reader_index` defaults to a fresh `deepest_reader_index(path)` for a caller that hasn't already
      # walked it; the ambiguous-crossing check has (it needs the same index to render the crossed path), so
      # it passes its own rather than paying for a second walk per failure.
      #
      # The `reader_index.nil?` branch mirrors `resolve_parent`'s own recipe-fallback guard rather than
      # covering a live case here: every indexed path's root ancestor is a `SubfieldTree.build` root, which
      # always carries a config, so an indexed config's `deepest_reader_index` never actually comes back nil.
      #
      # Shared with the ambiguous-crossing declaration check (SubfieldContradictions) so the runtime's
      # answer and the check's are the same answer, as `deepest_reader_index` already is.
      def self.crossed_node(config, path, reader_index = nil)
        return nil if path.ancestors.empty?

        reader_index ||= deepest_reader_index(path)
        return nil if reader_index.nil? || !crosses?(config, path, reader_index)

        path.ancestors[reader_index].first
      end

      # The node's reader-bearing config, if any. Every declared config generates a reader, so this is
      # the node's first config; an implicit node has no configs and returns nil.
      def self._reader_config(node)
        node.configs.first
      end

      # The reader to public_send at the deepest reader-bearing ancestor. When that ancestor is the
      # config's `on:` ANCHOR (the on: root's node), the reader is the one config.on names — which
      # disambiguates a MERGED anchor node (two routes to one wire path, distinct readers via `as:`) so a
      # descendant resolves through the route it actually anchored on, not the node's first-declared
      # config. A deeper reused declared intermediate (e.g. a `model:` hop crossed by a dotted `on:`) is
      # single-config in practice, so its own node reader is used. `anchor_index` is the on: root node's
      # chain index (parent_index minus the dotted-`on:` segments below the anchor).
      def self._deepest_reader_name(config, path, reader_index)
        return config.on.to_s.split(".").first.to_sym unless crosses?(config, path, reader_index)

        _reader_config(path.ancestors[reader_index].first).reader_as
      end

      # The parent value at the deepest reader-bearing ancestor. Its reader answers — except when NO config
      # bearing that name owns it (Contract#_reader_deferred?: an inferred confirmation companion whose
      # reader yielded to a method the author wrote). Dispatching then reads that method's answer instead of
      # the declared input, so the child would be validated against a value its parent's own contract never
      # saw. A reader-less config is resolved directly instead — `resolve_value`, the same seam inbound
      # validation takes for one — so both halves of a deferred pair and everything read off them agree on
      # the wire value.
      #
      # Asked of EVERY config bearing the name, because one node can hold a companion beside a declaration
      # of the same name (two spellings of one route reaching the same wire leaf). The companion is the one
      # that yielded, so the declaration's reader is what the name dispatches to and what the child must
      # read — the node-level half of the rule SubfieldTree.yields_reader_name? applies to anchor
      # registration.
      def self._read_deepest_reader(action, config, path, reader_index)
        reader = _deepest_reader_name(config, path, reader_index)
        bearers = path.ancestors[reader_index].first.configs.select { |c| c.reader_as == reader }
        deferred = bearers.first if bearers.any? && bearers.all? { |c| action.class.send(:_reader_deferred?, c) }

        deferred ? resolve_value(action, deferred) : action.public_send(reader)
      end

      # Fallback for configs outside the tree (ambient): read the `on:` root via its reader, dig the
      # rest raw. The resolving config's `method_call:` applies to those raw dig segments (the untree'd
      # analog of the per-hop implicit-intermediate rule in resolve_parent, PRO-2926).
      def self._resolve_parent_by_recipe(source, on, permit_method_call: false)
        root, *rest = on.to_s.split(".")
        value = _read_recipe_root(source, root)
        return value if rest.empty?

        Axn::Core::FieldResolvers.extract_or_nil(field: rest.join("."), provided_data: value, permit_method_call:)
      end

      # The two roots a recipe can name are not the same kind of thing, so they are not read the same way.
      #
      # `:ambient_context` is axn's own reserved parent — `expects :ambient_context` is refused, and the
      # tree treats an `on:` rooted there as ambient no matter what the class holds, so its value must come
      # from the framework's implementation. Dispatching it let a `def ambient_context` feed every ambient
      # subfield the user's object instead, which surfaced as a bogus "can't be blank" rather than an error
      # naming the cause.
      #
      # Any other root names a reader the USER declared, and dispatch is the point there: the declared
      # reader — theirs, or the one axn generated for their declaration — is exactly what should answer.
      def self._read_recipe_root(source, root)
        return Axn::Internal::ActionState.ambient_context(source) if root.to_sym == Axn::Core::AmbientContext::PARENT

        source.public_send(root)
      end

      # THE subfield value read — readers and validation share it: leaf-extract from the canonically
      # resolved parent, then value-level default fallback (PRO-2889). A declared default: guarantees
      # the RESOLVED value is never nil-by-omission even when the parent itself can't supply one (a
      # model:/non-object parent, a parent record whose attribute is nil, a malformed parent — none of
      # which axn can synthesize a value into). No wire data is written here and the parent's own value
      # stays untouched, so a nil-tolerant parent remains genuinely nil.
      def self.resolve_value(action, config)
        # Memoize on the action INSTANCE, keyed by config identity — mirrors the reader memoization
        # that already covers configs WITH a generated reader, extending it to the reader-less callers
        # this seam serves (validation's no-reader branch and resolve_model_via_id's
        # dotted-sibling path). Without it a reader-less config re-resolves once per ActiveModel
        # validator, re-running a Proc default each time — a Proc default must resolve at most once per
        # call. A config with a reader already memoizes, so this second layer is harmless there.
        # `key?` presence (not truthiness) so a nil/false resolved value memoizes too.
        cache = if action.instance_variable_defined?(:@__resolve_value_cache)
                  action.instance_variable_get(:@__resolve_value_cache)
                else
                  action.instance_variable_set(:@__resolve_value_cache, {}.compare_by_identity)
                end
        return cache[config] if cache.key?(config)

        parent = resolve_parent(action, config)
        raw = _memoized_raw_extract(action, config, parent)

        # Enqueue-time facet resolution wants the raw serialized value: no coerce/preprocess/default, so a
        # dynamic hook runs once at perform rather than also drifting/double-executing at enqueue.
        return raw if _raw_reads?(action)

        in_progress = _resolve_in_progress_set(action)
        # A field's value can't be defined in terms of its own transformed result: a re-entrant read of the
        # SAME config (its preprocess/default reading a subfield whose parent is this very field) returns the
        # pre-transform extract and breaks the cycle.
        return raw if in_progress[config]

        # A read taken while ANOTHER field's read-path TRANSFORM is mid-flight is provisional — it resolves
        # against a parent that hasn't settled yet (e.g. a parent whose own preprocess rewrites the value its
        # children read), so it is returned uncached and its reader memo is dropped once the outer field
        # settles, so a later read re-resolves against the now-settled parent. Keyed off the transform set,
        # NOT the cycle set: a model id LOOKUP (resolve_model_value) marks the cycle set but not this one —
        # its sibling `<field>_id` read is against an already-settled parent, so it must cache (PRO-2910).
        transforms = _transform_in_progress_set(action)
        nested = !transforms.empty?
        _mark_provisional_reader(action, config) if nested
        in_progress[config] = true
        transforms[config] = true
        begin
          # coerce:/preprocess:/default: all resolve here, on the read path (non-materializing, value-level
          # — the model PRO-2889 established for subfield defaults). No wire write-back and the parent's own
          # value stays untouched, so axn never mutates a caller-supplied object during resolution.
          value = _apply_read_path_transforms(action, config, raw, parent)
          value = Axn::Internal::FieldConfig.resolve_default(action, config) if value.nil? && config.applied_default?
        ensure
          in_progress.delete(config)
          transforms.delete(config)
        end
        return value if nested

        cache[config] = value
        _drop_provisional_reader_memos(action)
        value
      end

      # The per-action set of configs whose resolution is mid-flight (compare_by_identity), for CYCLE
      # detection. Shared by resolve_value and resolve_model_value so a value can't be defined in terms of
      # its own transform or default: a re-entrant read of the same config returns its pre-default value,
      # breaking the cycle.
      def self._resolve_in_progress_set(action)
        if action.instance_variable_defined?(:@__resolve_in_progress)
          action.instance_variable_get(:@__resolve_in_progress)
        else
          action.instance_variable_set(:@__resolve_in_progress, {}.compare_by_identity)
        end
      end

      # The per-action set of configs whose read-path TRANSFORM is mid-flight (compare_by_identity), the
      # provisional trigger. Distinct from the cycle set. A transform can rewrite the value its children read,
      # so a read taken during one is provisional: resolve_value marks it around coerce:/preprocess:/default:,
      # and resolve_model_value marks it around a record-supplying `default:` (which can read this model's own
      # subfields against a not-yet-settled record). A model id LOOKUP does NOT mark it — it rewrites nothing
      # its SIBLINGS read, so the sibling `<field>_id` it consults resolves against an already-settled parent
      # and must cache, not drop as provisional (PRO-2910). Non-empty means a read taken now is provisional.
      def self._transform_in_progress_set(action)
        if action.instance_variable_defined?(:@__transform_in_progress)
          action.instance_variable_get(:@__transform_in_progress)
        else
          action.instance_variable_set(:@__transform_in_progress, {}.compare_by_identity)
        end
      end

      # The RAW (pre-transform) extract of a config's field off its parent, memoized per-config so the wire
      # value is read at most once — critical when the field opts into `method_call:` and its reader is a
      # non-idempotent/one-shot method: the model finder's presence probe and the field's own reader must
      # see the SAME dispatch, not two (PRO-2910). Only a SETTLED read memoizes; a read taken during a parent
      # transform is provisional (the parent may still be rewritten), so it re-extracts against the settled
      # parent next time — mirroring the value cache and the reader-memo drop.
      def self._memoized_raw_extract(action, config, parent)
        memo = _raw_extract_memo(action)
        return memo[config] if memo.key?(config)

        raw = Axn::Core::FieldResolvers.extract_or_nil(field: config.field, provided_data: parent,
                                                       permit_method_call: config.method_call)
        memo[config] = raw if _transform_in_progress_set(action).empty?
        raw
      end

      def self._raw_extract_memo(action)
        if action.instance_variable_defined?(:@__raw_extract_memo)
          action.instance_variable_get(:@__raw_extract_memo)
        else
          action.instance_variable_set(:@__raw_extract_memo, {}.compare_by_identity)
        end
      end

      # Raw-read mode: enqueue-time facet resolution (Executor#resolve_inbound_facets) sets this so readers
      # return the raw serialized value instead of the transformed run-time value.
      def self._raw_reads?(action)
        action.instance_variable_defined?(:@__resolve_raw_reads) && action.instance_variable_get(:@__resolve_raw_reads)
      end

      # The [receiver, memo-ivar] where a config's reader memoizes — the single mirror of the
      # define_memoized_reader_method call sites. A subfield reader memoizes on the action under its
      # reader_as (ContractForSubfields#_define_subfield_reader/_define_subfield_model_reader); a top-level
      # model reader memoizes on the InternalContext facade under its WIRE field name (the facade method is
      # keyed by config.field — see InternalContext#_define_reader_for and _declared_fields). A top-level
      # plain reader isn't memoized, so its (facade, field) ivar simply never exists — dropping it is a no-op.
      def self._reader_memo_ref(action, config)
        if config.subfield?
          [action, :"@_memoized_reader_#{config.reader_as}"]
        else
          [Axn::Internal::ActionState.internal_context(action), :"@_memoized_reader_#{config.field}"]
        end
      end

      # A reader read while another field was mid-resolution memoized a provisional value (its parent
      # hadn't settled). Record the memo's [receiver, ivar] (via _reader_memo_ref, the single source of
      # truth for where a config's reader memoizes) so the outermost (settling) resolve can drop it,
      # forcing a fresh read against the settled parent — the lazy equivalent of the pipeline-boundary
      # memo clear. A top-level plain reader isn't memoized at all, so recording it is a harmless no-op
      # (there's no ivar to ever find set).
      def self._mark_provisional_reader(action, config)
        set = if action.instance_variable_defined?(:@__provisional_reader_memos)
                action.instance_variable_get(:@__provisional_reader_memos)
              else
                action.instance_variable_set(:@__provisional_reader_memos, [])
              end
        ref = _reader_memo_ref(action, config)
        set << ref unless set.include?(ref)
      end

      # Drop the reader memos that provisional reads populated during this (now-settled) resolution, on
      # their ACTUAL receiver (the action for a subfield, the InternalContext facade singleton for a
      # top-level model reader) — so a provisionally-resolved value never survives a settled resolution
      # regardless of where its memo lives. This only fires for readers that were actually read
      # provisionally; a normal (non-provisional) top-level model read is untouched, so its finder isn't
      # re-run on every call.
      def self._drop_provisional_reader_memos(action)
        return unless action.instance_variable_defined?(:@__provisional_reader_memos)

        action.remove_instance_variable(:@__provisional_reader_memos).each do |receiver, ivar|
          receiver.remove_instance_variable(ivar) if receiver.instance_variable_defined?(ivar)
        end
      end

      # coerce → preprocess, applied to a resolved value on the read path at any depth (minus default:,
      # which the caller applies after). Preprocess is skipped when the parent is absent (nil): an
      # absent subfield has no value to transform. coerce_value no-ops on a nil/non-String value, so
      # coercion needs no guard.
      def self._apply_read_path_transforms(action, config, value, parent)
        coerce_input_types = Axn::Internal::CurrentCallOptions.coerce_input_types_for(action)
        value = Axn::Internal::Coercion.coerce_config_value(value, config, coerce_input_types:)
        value = Axn::Internal::FieldConfig.resolve_preprocess(action, config, value) if config.preprocess && !parent.nil?
        value
      end

      # The model-field value read: a directly-supplied RECORD (authoritative), else a lookup by the
      # `<field>_id` — routed through that id's read-path transform when the sibling is declared, or the raw
      # caller token when it isn't (PRO-2910) — then a record-supplying default:. Non-materializing — the
      # parent's own value stays untouched. Used by both the InternalContext facade's top-level model reader
      # (depth 0) and _define_subfield_model_reader (depth ≥ 1). `options` is the syntactic-sugar-processed
      # model options for this config.
      def self.resolve_model_value(action, config, options)
        parent = resolve_parent(action, config)

        # Raw-read mode (enqueue-time facets): resolve the record straight from the raw parent — raw record
        # or a straight RAW-id lookup, no transform/rescue/default — so the facet mirrors the serialized
        # payload rather than a run-time-only transformed/rescued/defaulted value.
        return _model_from_raw_parent(config, options, parent) if _raw_reads?(action)

        # A directly-supplied RECORD is authoritative and read raw — never overridden by an id lookup. Read
        # the record key through the per-config raw memo so it (and its `method_call:` dispatch) is read at
        # most once — shared with the model-consistency check, which reads the same key (PRO-2910).
        present_record = _memoized_raw_extract(action, config, parent).presence

        in_progress = _resolve_in_progress_set(action)
        # A model field's value can't be defined in terms of its own resolution: a record-supplying `default:`
        # OR a sibling `<field>_id` `default:` that reads this same model reader re-enters here. The re-entrant
        # read returns the present record or a RAW-id lookup from the parent ALONE — no transform, rescue, or
        # default — breaking the cycle so the Proc can complete. Mirrors resolve_value's re-entrancy guard;
        # the marker is set BEFORE the id lookup and the default so both re-entry routes are covered.
        return present_record || _model_from_raw_parent(config, options, parent) if in_progress[config]

        # This model read is provisional only when a PARENT transform is mid-flight (keyed off the transform
        # set, like resolve_value) — a record resolved against an unsettled parent must be dropped and re-read.
        transforms = _transform_in_progress_set(action)
        nested = !transforms.empty?
        _mark_provisional_reader(action, config) if nested
        in_progress[config] = true
        begin
          record = present_record
          # The id LOOKUP reads a SIBLING `<field>_id`, whose parent is already settled — so it is NOT a
          # transform-in-progress (only the cycle set is marked). That lets the sibling id reader cache and
          # be reused by its own later validation read, running a stateful preprocess:/default: at most once
          # and keeping the record's id in agreement with what the `<field>_id` reader sees (PRO-2910).
          record ||= resolve_model_via_id(action, config, options, parent)
          # The record-supplying `default:`, by contrast, CAN read this model's own subfields (`on:` this
          # field) against a record that hasn't settled yet, so it marks the transform set: those child reads
          # are provisional and re-resolve against the settled record once the default returns (PRO-2908).
          if record.nil? && config.applied_default?
            transforms[config] = true
            begin
              record = Axn::Internal::FieldConfig.resolve_default(action, config)
            ensure
              transforms.delete(config)
            end
          end
        ensure
          in_progress.delete(config)
        end
        # A read taken while another field is mid-resolution is provisional — return it without dropping the
        # provisional memos (that happens only at the outermost, settled resolve, exactly as in resolve_value).
        return record if nested

        _drop_provisional_reader_memos(action)
        record
      end

      # A present record OR a straight RAW-id lookup off the parent — the Model resolver's own
      # record-or-derive with no read-path transform. The raw-read (enqueue) and re-entrancy fallbacks.
      def self._model_from_raw_parent(config, options, parent)
        Axn::Core::FieldResolvers.resolve(type: :model, field: config.field, options:,
                                          provided_data: parent, permit_method_call: config.method_call)
      end

      # Resolve the model record from its `<field>_id` (a present RECORD is already handled by the caller,
      # so this derives from the id ALONE). The lookup token is a DECLARED sibling `<field>_id`'s read-path
      # transform (its own reader, via _declared_id_token) so the record resolves from the SAME value the
      # `<field>_id` reader, its validation, and the model-consistency check all see; with NO `<field>_id`
      # declared it is the caller's RAW token off the parent (no transform). Either way the record is looked
      # up through a SYNTHETIC hash keyed by the id key: the Model resolver finds no record key there, so it
      # goes straight to the id derivation — the caller already read the record key (present_record), and
      # re-reading it here would dispatch a one-shot/stateful record reader a second time (PRO-2910).
      def self.resolve_model_via_id(action, config, options, parent)
        id_key = Axn::Internal::FieldConfig.model_id_key(config.field)
        configs = sibling_id_configs(action, config)
        token =
          if configs.empty?
            Axn::Core::FieldResolvers.extract_or_nil(field: id_key, provided_data: parent, permit_method_call: config.method_call)
          else
            _declared_id_token(action, configs)
          end
        return nil if token.nil?

        Axn::Core::FieldResolvers.resolve(type: :model, field: config.field, options:, provided_data: { id_key => token })
      end

      # The effective transformed `<field>_id` token from the DECLARED sibling routes (`configs`, already the
      # priority-ordered sibling_id_configs), shared by the record lookup and the consistency check so they can
      # never disagree about which value a present record/lookup sees. Reads the routes in order via their own
      # readers (resolve_value); each route's presence probe reads the SAME memoized raw its reader consumes
      # (_memoized_raw_extract), so a `method_call:` id whose reader is a non-idempotent method dispatches at
      # most once (PRO-2910). Each route reads its own wire key off its own parent, so it also carries that
      # route's own `method_call:` — the id declaration governs reading the id key, not the model field's:
      #   * a PRESENT raw id reads that route, which is AUTHORITATIVE: the first route to yield a non-nil value
      #     wins, and a present value it resolves to nil (its preprocess maps it to nil, no own default) is
      #     genuinely nil for this model, so we STOP rather than re-reading through another route;
      #   * an ABSENT raw id reads ONLY defaulted routes (Schema.usable_id_token_default?) — the PRO-2889
      #     omitted-id rescue — and skips a route that would resolve nil anyway AND would fire an unguarded
      #     `preprocess:` on the absent value (e.g. `nil.strip`).
      # Returns nil when no eligible route yields a token. Callers separate the "no declared `<field>_id` at
      # all" case via sibling_id_configs.empty? (there the caller's raw token is used).
      def self._declared_id_token(action, configs)
        configs.each do |sibling_config|
          raw = _memoized_raw_extract(action, sibling_config, resolve_parent(action, sibling_config))
          # Absent id: only a defaulted route can rescue; skip the rest (they resolve nil and would run an
          # unguarded preprocess on the absent value).
          next if raw.nil? && !Axn::Internal::Reflection::Schema.usable_id_token_default?(sibling_config)

          value = action.public_send(sibling_config.reader_as)
          return value unless value.nil?
          # A PRESENT id this route resolves to nil is genuinely nil — don't fall through to another route.
          return nil unless raw.nil?
        end
        nil
      end

      # The declared `<field>_confirmation` config on the SAME route as `config`, or nil — the companion the
      # author declared, or the one `confirmation:` declared implicitly for them (Contract
      # #_confirmation_companion_configs), which are the same kind of config by then. A confirmation
      # pair is one route's contract: unlike `sibling_id_configs`, which also accepts the route owning the
      # canonical `<field>_id` reader because an id may legitimately be declared beside a different model, a
      # confirmation compares against the companion declared beside THIS field and nothing else.
      def self.sibling_confirmation_config(action, config)
        key = :"#{config.field}_confirmation"
        candidates =
          if config.on.nil?
            action.class.internal_field_configs.select { |c| c.field == key }
          else
            action.class.send(:subfield_configs).select { |c| c.field == key }
          end

        candidates.find { |c| c.on.to_s == config.on.to_s }
      end

      # The declared sibling `<field>_id` routes that may supply a `model:` field's lookup token, in the order
      # `_declared_id_token` reads them (for both the record lookup and the consistency check, so the two can
      # never disagree about which route's transformed id a present record/lookup sees). This gathers the
      # candidates declaring that wire key; which of them are ELIGIBLE is FieldConfig.id_token_routes, THE
      # precedence, shared with the declaration-time rescue credit — a present token the chosen route maps to
      # nil is genuinely nil for this model (_declared_id_token stops there), never re-read through another.
      #
      # Empty when no eligible `<field>_id` is declared (the caller's raw token off the parent carries no
      # transform) or when the config isn't in either subfield index (an ambient config falls back to the
      # ambient-scoped tree).
      def self.sibling_id_configs(action, config)
        path = action.class._resolved_subfields.index[config] || action.class._ambient_subfield_tree.index[config]
        return [] if path.nil?

        id_key = Axn::Internal::FieldConfig.model_id_key(config.field)
        # Candidate sibling `<field>_id` configs: another top-level root at depth 0 (a declared field, not a
        # child of parent_node), else the children of the leaf's own wire parent.
        candidates =
          if path.ancestors.empty?
            action.class.internal_field_configs.select { |c| c.field == id_key }
          else
            path.parent_node.children[id_key.to_sym]&.configs || []
          end

        Axn::Internal::FieldConfig.id_token_routes(config, candidates)
      end

      # The read-path internals of the four public entry points above (`resolve_parent`, `resolve_value`,
      # `resolve_model_value`, `resolve_model_via_id`). Declared in one place rather than beside each
      # definition because they interleave with those entry points; every one of them is reached with an
      # implicit receiver from module scope, so nothing here needs a `send`. Two `_`-prefixed siblings are
      # deliberately absent and stay public: `Core::Executor` calls `_memoized_raw_extract` and
      # `_declared_id_token` on this module by name, and `ClassMethods`' `<field>_id` companion reader
      # calls `_declared_id_token` the same way.
      private_class_method :crosses?, :_reader_config, :_deepest_reader_name, :_read_deepest_reader,
                           :_resolve_parent_by_recipe, :_read_recipe_root,
                           :_resolve_in_progress_set, :_transform_in_progress_set, :_raw_extract_memo,
                           :_raw_reads?, :_reader_memo_ref, :_mark_provisional_reader,
                           :_drop_provisional_reader_memos, :_apply_read_path_transforms,
                           :_model_from_raw_parent

      module ClassMethods
        # The class's canonical resolved-subfield structure (PRO-2883), built lazily and cached on
        # the class. Cache validity is decided by IDENTITY of the two config arrays: both are
        # copy-on-write class_attributes mutated exclusively via `+=`, so any declaration — on this
        # class or a subclass — mints new arrays and the stale entry misses on `equal?`. That gives
        # invalidation with no explicit hooks (a future mutation site is auto-covered), no
        # nil-memoization footgun (validity never consults the value), and free copy-on-write
        # subclass inheritance (an undeclaring subclass reads the superclass's arrays and builds an
        # identical artifact once). The artifact is deep-frozen and published in a single ivar
        # write, so a first-call race between threads is benign.
        def _resolved_subfields
          fields = internal_field_configs
          subfields = subfield_configs
          cached = @_axn_resolved_subfields
          return cached.value if cached && cached.fields.equal?(fields) && cached.subfields.equal?(subfields)

          value = Axn::Internal::ResolvedSubfields.build(fields, subfields)
          @_axn_resolved_subfields = ResolvedSubfieldsCacheEntry.new(fields:, subfields:, value:)
          value
        end

        # Everything below is reached only with an implicit receiver, from here and from the other declaration
        # modules extended onto the same class (`expects` routes a subfield declaration into
        # `_expects_subfields`). It is private because an `_`-prefixed name in a module extended onto every
        # action class otherwise lands there as a PUBLIC singleton method, so the convention and the surface
        # disagree. `_resolved_subfields` stays public above: reflection, the executor and the facade inspector
        # all read the resolved tree off the action class from other files.
        private

        def _expects_subfields( # rubocop:disable Metrics/ParameterLists
          *fields,
          on:,
          allow_blank: false,
          allow_nil: false,
          allow_empty: nil,
          optional: false,
          default: nil,
          preprocess: nil,
          sensitive: false,
          metadata: {},
          reader_names: {},
          user_facing: false,
          method_call: false,
          **validations
        )
          # `on:` arrives canonicalized (a Symbol — see `expects`), so every read of it here and downstream is
          # Ruby's own and they cannot disagree about which route was declared.
          #
          # `on:` may be a dotted path (e.g. "address.billing"); the *root* segment must be declared.
          # It's resolved by calling the parent's reader (`resolve_parent` → public_send), so it must
          # name a reader — i.e. the alias when the parent was declared with `as:`/`prefix:`, not the
          # underlying wire key (which has no reader of its own once renamed).
          root = on.to_s.split(".").first.to_sym
          unless root == Axn::Core::AmbientContext::PARENT || _reader_owners.key?(root)
            # The missing SEGMENT is named through `Symbol#inspect`, which supplies its own colon — so the
            # template carries none. `inspect` also escapes bytes with no UTF-8 rendering to ASCII and cannot
            # be overridden (Symbol takes neither a subclass nor a singleton), which is what lets one form
            # serve every route: `:baz`, `:a` for a dotted `on: "a.b"` (the segment that is actually missing,
            # not the whole route), `:café`, and `:"bad\xFF"`.
            raise ArgumentError,
                  "expects called with `on: #{_schema_name_label(on)}`, but no such reader exists " \
                  "(are you sure you've declared a field — or alias — named #{root.inspect}?)"
          end

          # An ambient subfield's value is framework-supplied (the ambient provider /
          # CurrentAttributes), not caller input — there is no user to face, so reclassifying its
          # violation as user-facing is a category error.
          if user_facing && _on_roots_at_ambient?(on)
            raise ArgumentError,
                  "`user_facing:` is not supported for an ambient_context subfield " \
                  "(ambient values are framework-supplied, not caller input)"
          end

          # Deep ambient nesting — a dotted `on:` rooted at ambient (`on: "ambient_context.request"`),
          # a dotted subfield NAME on an ambient parent (`expects "request.ip", on: :ambient_context`),
          # and a subfield nested UNDER an ambient subfield (`expects :ip, on: :request`) — is fully
          # supported (PRO-2909): runtime resolution walks these, and `_filter_to_declared` rebuilds the
          # filtered ambient hash along each declared PATH, so a nested leaf resolves while undeclared
          # siblings are dropped. `default:`/`preprocess:`/`coerce:` resolve on the same non-mutating read
          # path (`resolve_value`) as every other subfield, so they apply here too — no write-back to
          # `provided_data` is involved. `user_facing:` stays rejected (above): an ambient value is
          # framework-supplied, so there is no caller to face regardless of resolution mechanism.

          # A `confirmation:` subfield declares its `<field>_confirmation` companion on the SAME `on:` route
          # (a confirmation pair is one route's contract), before any check runs — so from here on the
          # companion is an ordinary member of the batch, judged and committed with the rest, exactly as on
          # the top-level route.
          declared = _parse_subfield_configs(*fields, on:, allow_blank:, allow_nil:, allow_empty:, optional:, preprocess:, sensitive:, default:,
                                                      metadata:, reader_names:, user_facing:, method_call:, **validations)

          (declared + _confirmation_companion_configs(declared, existing: subfield_configs)).tap do |configs|
            # An explicit declaration of a name an earlier `confirmation:` generated implicitly REPLACES that
            # companion, including the reader it already generated — withdrawn below unless the replacement
            # reclaims the name.
            retained, superseded = _partition_superseded_confirmation_companions(subfield_configs, configs)

            _reject_duplicate_fields!(retained, configs)
            # The resolved half of the same identity rule: two supported spellings of one route (a dotted
            # `on:` and a subfield reader or its `as:` alias) resolve to one parent while differing as
            # written, so leaf names that collapse onto one property need the tree to be seen at all.

            # Validate reader-name uniqueness up front (no side effects), so this error — like the checks
            # above (the dotted-name model: and model-batch-id rejections in _parse_subfield_configs) —
            # leaves the class untouched.
            _validate_subfield_reader_names!(configs)

            # Contradiction-only contracts raise BEFORE any class mutation (PRO-2889): the candidate
            # tree includes the prospective configs, so a new required descendant that kills an
            # already-declared tolerance is caught at the declaration that completes it. The shared tree
            # drops ambient configs, so the ambient subtree is checked separately on its own scoped tree
            # (PRO-2909) — same candidate set, same checks.
            Axn::Core::Contract::SubfieldContradictions.check!(internal_field_configs, retained + configs)
            _check_ambient_subfield_contradictions!(retained + configs)
            _check_ambient_shape_placement!(retained + configs)

            # Every declaration check has passed; NOW mutate the class. Deferring both the config commit
            # AND reader generation to here (after all checks) means a rescued declaration error — a Rails
            # reload path, metaprogrammed construction, a test — never leaves the class carrying an orphaned
            # config or generated reader, so a corrected retry starts clean.
            # Copy-on-write + freeze: `<<` would mutate the superclass's contract, and
            # identity-keyed caching relies on replacement.
            self.subfield_configs = (retained + configs).freeze
            # Before the new readers, so a name the replacement reclaims is redefined rather than dropped.
            superseded.each { |c| _withdraw_inferred_reader!(c.reader_as) }
            _define_subfield_readers!(configs)
          end
        end

        # A route is rendered as the JSON property it canonicalizes to, never interpolated raw: `on:` may hold
        # bytes with no UTF-8 rendering, and joining those into this UTF-8 message would raise
        # Encoding::CompatibilityError from the reporting itself — surfacing an encoding failure instead of the
        # missing-reader defect being reported. (Whether an unrenderable segment is a defect in its own right
        # depends on whether the schema EMITS it, which the emitted-name walk decides.)
        def _schema_name_label(name) = Axn::Internal::Reflection::PropertyNames.renderable_label(name)

        # True when on:'s chain ultimately roots at :ambient_context — directly (`on: :ambient_context`),
        # via a dotted path, or by pointing at another subfield that itself roots at ambient. Each hop
        # follows the config that OWNS the segment's reader (_reader_owners), the same resolution `on:`
        # itself takes; a top-level owner ends the walk, since only a subfield carries an `on:` to follow.
        def _on_roots_at_ambient?(on)
          owners = _reader_owners
          seen = []
          segment = on.to_s.split(".").first.to_sym
          loop do
            return true if segment == Axn::Core::AmbientContext::PARENT
            return false if seen.include?(segment)

            seen << segment
            parent = owners[segment]
            return false unless parent&.subfield?

            segment = parent.on.to_s.split(".").first.to_sym
          end
        end

        def _parse_subfield_configs( # rubocop:disable Metrics/ParameterLists
          *fields,
          on:,
          allow_blank: false,
          allow_nil: false,
          allow_empty: nil,
          optional: false,
          preprocess: nil,
          sensitive: false,
          default: nil,
          metadata: {},
          reader_names: {},
          user_facing: false,
          method_call: false,
          **validations
        )
          # A subfield is the on:-carrying case of the shared top-level config builder; with the ambient
          # coerce/shape guards and the dotted-name model guard gone, no per-config post-check remains.
          _parse_field_configs(*fields, on:, allow_blank:, allow_nil:, allow_empty:, optional:, preprocess:, sensitive:, default:,
                                        metadata:, reader_names:, user_facing:, method_call:, **validations)
        end

        # Reader-name uniqueness across the prospective batch and everything already defined — a pure
        # pre-check (no methods defined) run before any reader is generated, so a duplicate raises before
        # the class is mutated. Every EXPLICITLY declared subfield gets a reader (canonical `on:` resolution
        # public_sends the deepest reader-bearing ancestor, so a silently-skipped reader would resolve the
        # wrong value), so a collision between two of them is a declaration error — resolved by renaming,
        # never by suppression.
        #
        # An IMPLICIT confirmation companion is on neither side of that bar. Its own reader is inferred, so
        # it defers to whatever holds the name instead of raising (`_define_subfield_readers!`); and a name
        # only an inferred reader holds is free for an explicit declaration to take, which is what makes the
        # author's own `<field>_confirmation` line replace the companion axn generated for them.
        def _validate_subfield_reader_names!(configs)
          seen = []
          configs.each do |config|
            next if config.confirmation_for

            reader = config.reader_as
            # Read natively, like every other method-table question a declaration guard asks: `self` is the
            # author's class, and a singleton `method_defined?` of its own answering false would admit the
            # duplicate this refuses.
            taken = Axn::Internal::NativeMethods.declared_instance_method(self, reader) && !_inferred_reader?(reader)
            if taken || seen.include?(reader)
              raise ArgumentError,
                    "expects does not support duplicate sub-keys (i.e. `#{reader}` is already defined) — " \
                    "rename this subfield's reader, e.g. `expects :#{config.field}, on: #{config.on.inspect}, " \
                    "as: :#{config.on.to_s.tr('.', '_')}_#{config.field}` (or use prefix: for several at once)"
            end

            seen << reader
          end
        end

        # Generate the readers for an already-validated, already-committed batch of subfield configs.
        # Called only after every declaration check has passed, so it performs side effects without raising.
        #
        # Two passes: every EXPLICIT declaration's primary reader first, then everything INFERRED (an
        # implicit confirmation companion's own reader, the boolean `?` predicates, the model `<field>_id`
        # readers). An inferred reader defers — with a debug breadcrumb, via `_reader_name_available?` — to
        # any explicit reader of the same name; deferring the whole inferred pass until every primary exists
        # makes that yielding order-independent, matching top-level `expects`. Interleaving the two (an
        # inferred reader generated before a later same-named primary) would let the primary silently
        # clobber it.
        def _define_subfield_readers!(configs)
          explicit, inferred = configs.partition { |c| c.confirmation_for.nil? }
          explicit.each { |c| _define_subfield_reader(c) }

          # An inferred companion yields WHOLE — its own reader and the predicate riding on it — to a
          # same-named method already present, so a deferred companion never leaves half a reader behind.
          # The config still stands and is validated, redacted and reflected exactly as it would be with a
          # reader of its own — validation resolves a reader-less config directly (_validation_reader_for).
          generated = inferred.filter_map do |config|
            next unless _reader_name_available?(config.reader_as, kind: "confirmation companion")

            _define_subfield_reader(config)
            config
          end

          (explicit + generated).each { |c| _define_subfield_companion_readers(c) }
        end

        # `reader` is the accessor's name (may be aliased via as:/prefix:); the wire key it extracts
        # from the `on:` parent is the config's own field (resolve_value reads it).
        def _define_subfield_reader(config)
          reader = config.reader_as

          # Reader-name uniqueness is validated up front by _validate_subfield_reader_names! before any
          # reader is generated, so there is no duplicate to guard against here.

          if config.validations.key?(:model)
            _define_subfield_model_reader(config)
          else
            Axn::Internal::Memoization.define_memoized_reader_method(_reader_target_for(config), reader) do
              Axn::Core::ContractForSubfields.resolve_value(self, config)
            end
          end
        end

        # Auto-generated companion readers for a config: the boolean `?` predicate and the model
        # `<field>_id` reader. Defined in a second pass (see _define_subfield_readers!) so each yields to
        # any explicit same-named reader regardless of declaration order.
        def _define_subfield_companion_readers(config)
          _define_boolean_predicate_reader(config.reader_as, target: _reader_target_for(config)) if config.boolean?
          return unless config.validations.key?(:model)

          _define_subfield_model_id_reader(config, _subfield_model_options(config))
        end

        # Syntactic-sugar processing for a subfield `model:`, keyed on the field name so a defaulted
        # `klass` derives from it (`widget` → `Widget`).
        def _subfield_model_options(config)
          Axn::Validators::ModelValidator.apply_syntactic_sugar(config.validations[:model], [config.field])
        end

        def _define_subfield_model_reader(config)
          processed_options = _subfield_model_options(config)
          Axn::Internal::Memoization.define_memoized_reader_method(self, config.reader_as) do
            Axn::Core::ContractForSubfields.resolve_model_value(self, config, processed_options)
          end
        end

        # The subfield analog of `_define_model_id_reader`: yields the `<field>_id` token and otherwise
        # shares the top-level reader's semantics via `_define_model_id_reader_from`. Like the top-level
        # companion, it reuses the SAME declared `<field>_id` token the record lookup and the consistency
        # check consume (sibling_id_configs + _declared_id_token), so this companion agrees with them and
        # with the declared `<field>_id`'s own (possibly `as:`-aliased) reader — never the raw wire value
        # when a transform is declared (PRO-2910). An undeclared id is the caller's raw token off the `on:`
        # parent.
        def _define_subfield_model_id_reader(config, processed_options)
          by_primary_key = processed_options[:finder] == :find
          _define_model_id_reader_from(reader: config.reader_as, source_field: config.field, by_primary_key:) do |id_key|
            sibling_configs = Axn::Core::ContractForSubfields.sibling_id_configs(self, config)
            if sibling_configs.empty?
              parent = Axn::Core::ContractForSubfields.resolve_parent(self, config)
              Axn::Core::FieldResolvers.extract_or_nil(field: id_key, provided_data: parent, permit_method_call: config.method_call)
            else
              Axn::Core::ContractForSubfields._declared_id_token(self, sibling_configs)
            end
          end
        end
      end
    end
  end
end
