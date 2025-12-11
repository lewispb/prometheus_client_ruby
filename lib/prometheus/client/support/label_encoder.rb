# frozen_string_literal: true

require 'cgi'

module Prometheus
  module Client
    module Support
      # Encodes and decodes label names and values for filesystem-safe storage.
      #
      # Uses URL encoding (percent encoding) to handle UTF-8 strings safely.
      # This preserves all Unicode characters while creating filesystem-safe names.
      #
      # @example
      #   LabelEncoder.encode("日本語ラベル")
      #   # => "%E6%97%A5%E6%9C%AC%E8%AA%9E%E3%83%A9%E3%83%99%E3%83%AB"
      #
      #   LabelEncoder.decode("%E6%97%A5%E6%9C%AC%E8%AA%9E%E3%83%A9%E3%83%99%E3%83%AB")
      #   # => "日本語ラベル"
      #
      #   LabelEncoder.encode("path/to/resource")
      #   # => "path%2Fto%2Fresource"
      #
      module LabelEncoder
        # Characters safe in filenames that don't need encoding
        # Alphanumeric plus hyphen and underscore
        SAFE_CHARS = /[^a-zA-Z0-9_\-]/

        module_function

        # Encode a label name or value for filesystem-safe storage.
        # Uses URL encoding to handle UTF-8 and special characters.
        #
        # @param value [String] Original label name or value (UTF-8)
        # @return [String] Encoded value safe for filenames
        def encode(value)
          str = value.to_s
          # Ensure UTF-8 encoding
          str = str.encode('UTF-8') unless str.encoding == Encoding::UTF_8

          # URL encode non-safe characters
          encoded = str.gsub(SAFE_CHARS) do |char|
            char.bytes.map { |b| "%%%02X" % b }.join
          end

          # Limit length to avoid filesystem issues (255 byte limit on most systems)
          # Leave room for metric name, separators, and extension
          encoded[0, 128]
        end

        # Decode a label name or value from filesystem storage.
        #
        # @param value [String] Encoded label name or value
        # @return [String] Original UTF-8 string
        def decode(value)
          # CGI.unescape handles percent-encoded UTF-8 correctly
          CGI.unescape(value.to_s)
        end

        # Encode a full label set for use in a filename.
        # Format: key1_value1__key2_value2
        #
        # @param labels [Hash] Label name => value pairs
        # @return [String] Encoded string for filename
        def encode_labels(labels)
          return "default" if labels.nil? || labels.empty?

          labels.sort.map do |key, value|
            "#{encode(key)}_#{encode(value)}"
          end.join("__")
        end

        # Decode a filename label string back to a hash.
        #
        # @param encoded [String] Encoded label string from filename
        # @return [Hash] Label name => value pairs (symbols as keys)
        def decode_labels(encoded)
          return {} if encoded == "default" || encoded.nil? || encoded.empty?

          result = {}
          pairs = encoded.split("__")

          pairs.each do |pair|
            # Split on first underscore only (value may contain encoded underscores)
            key, value = pair.split("_", 2)
            next unless key && value

            result[decode(key).to_sym] = decode(value)
          end

          result
        end
      end
    end
  end
end
