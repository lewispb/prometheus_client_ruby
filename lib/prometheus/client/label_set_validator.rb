# encoding: UTF-8

module Prometheus
  module Client
    # LabelSetValidator ensures that all used label sets comply with the
    # Prometheus specification.
    #
    # Supports both legacy label names (ASCII alphanumeric + underscore) and
    # UTF-8 label names (Prometheus 2.40+).
    class LabelSetValidator
      BASE_RESERVED_LABELS = [:pid].freeze

      # Legacy label name pattern (pre-2.40): ASCII letters, digits, underscore
      LEGACY_LABEL_NAME_REGEX = /\A[a-zA-Z_][a-zA-Z0-9_]*\Z/

      # UTF-8 label name pattern (2.40+): Any valid UTF-8 string that doesn't
      # start with __ (reserved for internal use)
      # Note: Empty strings and strings with only whitespace are not allowed
      UTF8_LABEL_NAME_REGEX = /\A(?!__).+\Z/m

      class LabelSetError < StandardError; end
      class InvalidLabelSetError < LabelSetError; end
      class InvalidLabelError < LabelSetError; end
      class ReservedLabelError < LabelSetError; end

      attr_reader :expected_labels, :reserved_labels

      def initialize(expected_labels:, reserved_labels: [])
        @expected_labels = expected_labels.sort
        @reserved_labels = BASE_RESERVED_LABELS + reserved_labels
      end

      def validate_symbols!(labels)
        unless labels.respond_to?(:all?)
          raise InvalidLabelSetError, "#{labels} is not a valid label set"
        end

        labels.all? do |key, _|
          validate_symbol(key)
          validate_name(key)
          validate_reserved_key(key)
        end
      end

      def validate_labelset!(labelset)
        begin
          return labelset if keys_match?(labelset)
        rescue ArgumentError
          # If labelset contains keys that are a mixture of strings and symbols, this will
          # raise when trying to sort them, but the error should be the same:
          # InvalidLabelSetError
        end

        raise InvalidLabelSetError, "labels must have the same signature " \
                                    "(keys given: #{labelset.keys} vs." \
                                    " keys expected: #{expected_labels}"
      end

      private

      def keys_match?(labelset)
        labelset.keys.sort == expected_labels
      end

      def validate_symbol(key)
        return true if key.is_a?(Symbol)

        raise InvalidLabelError, "label #{key} is not a symbol"
      end

      def validate_name(key)
        key_str = key.to_s

        if key_str.start_with?('__')
          raise ReservedLabelError, "label #{key} must not start with __"
        end

        if key_str.empty? || key_str.strip.empty?
          raise InvalidLabelError, "label name cannot be empty or whitespace-only"
        end

        # Ensure valid UTF-8 encoding
        unless key_str.valid_encoding?
          raise InvalidLabelError, "label name must be valid UTF-8"
        end

        true
      end

      def validate_reserved_key(key)
        return true unless reserved_labels.include?(key)

        raise ReservedLabelError, "#{key} is reserved"
      end
    end
  end
end
