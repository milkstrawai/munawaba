# frozen_string_literal: true

module Munawaba
  module Notifications
    module Context
      class V1
        class Invalid < Munawaba::Error
          def initialize(*) = super("Invalid delivery context")
        end

        OVERRIDES = {
          "override_created" => %w[override_id],
          "override_superseded" => %w[override_id ended_override_id],
          "override_revoked" => %w[ended_override_id],
          "override_restored_to_base" => %w[ended_override_id]
        }.freeze

        def self.validate!(kind:, context:)
          raise Invalid unless context.is_a?(Hash) && context.keys.all? { |key| key.is_a?(String) }
          raise Invalid unless context["schema_version"].is_a?(Integer) && context["schema_version"] == 1

          keys = ["schema_version"]
          case kind.to_s
          when "advance_reminder", "shift_start", "test"
            nil
          when "assignment_change"
            transition = OVERRIDES[context["transition_type"]]
            raise Invalid unless transition

            keys += %w[transition_type previous_person_id new_person_id] + transition
            raise Invalid if context["previous_person_id"] == context["new_person_id"]
          when "next_assignment_change"
            # Accept the old activity reference without requiring activity rows to exist.
            context = context.except("operation_id")
            keys += %w[previous_next_person_id new_next_person_id described_shift_id]
            raise Invalid if context["previous_next_person_id"] == context["new_next_person_id"]
          else
            raise Invalid
          end
          raise Invalid unless keys.sort == context.keys.sort

          keys.grep(/_id\z/).each do |key|
            raise Invalid unless context[key].is_a?(Integer) && context[key] > 0
          end
          raise Invalid if JSON.generate(context).bytesize > 16_384

          context.slice(*keys).freeze
        rescue JSON::GeneratorError, EncodingError
          raise Invalid
        end

        def self.valid?(kind:, context:)
          validate!(kind: kind, context: context)
          true
        rescue Invalid
          false
        end

        def self.build(kind:, **values)
          validate!(kind: kind, context: { "schema_version" => 1 }.merge(values.stringify_keys))
        end
      end
    end
  end
end
