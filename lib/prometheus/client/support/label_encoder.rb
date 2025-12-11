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
      # Key-value pairs use '=' as separator (encoded as %3D in values).
      # Multiple pairs use '&' as separator (encoded as %26 in values).
      # This ensures unambiguous round-trip encoding.
      #
      # @example
      #   LabelEncoder.encode("日本語ラベル")
      #   # => "%E6%97%A5%E6%9C%AC%E8%AA%9E%E3%83%A9%E3%83%99%E3%83%AB"
      #
      #   LabelEncoder.encode_labels({ http_method: "GET", path: "/users" })
      #   # => "http_method=GET&path=%2Fusers"
      #
      module LabelEncoder
        # Characters safe in filenames that don't need encoding
        # Alphanumeric plus hyphen and underscore
        # Note: '=' and '&' are intentionally NOT safe - they're our delimiters
        SAFE_CHARS = /[^a-zA-Z0-9_\-]/

        # Delimiter between key and value
        KV_SEPARATOR = '='
        # Delimiter between pairs
        PAIR_SEPARATOR = '&'

        module_function

        # Encode a label name or value for filesystem-safe storage.
        # Uses URL encoding to handle UTF-8 and special characters.
        #
        # @param value [String] Original label name or value (UTF-8)
        # @return [String] Encoded value safe for filenames
        def encode(value)
          str = value.to_s
          str = str.encode('UTF-8') unless str.encoding == Encoding::UTF_8

          encoded = str.gsub(SAFE_CHARS) { |char| char.bytes.map { "%%%02X" % _1 }.join }

          # Limit length to avoid filesystem issues (255 byte limit on most systems)
          encoded[0, 128]
        end

        # Decode a label name or value from filesystem storage.
        #
        # @param value [String] Encoded label name or value
        # @return [String] Original UTF-8 string
        def decode(value)
          CGI.unescape(value.to_s)
        end

        # Encode a full label set for use in a filename.
        # Format: key1=value1&key2=value2
        #
        # @param labels [Hash] Label name => value pairs
        # @return [String] Encoded string for filename
        def encode_labels(labels)
          return "default" if labels.nil? || labels.empty?

          labels.sort.map { |key, value| "#{encode(key)}#{KV_SEPARATOR}#{encode(value)}" }
                .join(PAIR_SEPARATOR)
        end

        # Decode a filename label string back to a hash.
        #
        # @param encoded [String] Encoded label string from filename
        # @return [Hash] Label name => value pairs (symbols as keys)
        def decode_labels(encoded)
          return {} if encoded == "default" || encoded.nil? || encoded.empty?

          encoded.split(PAIR_SEPARATOR).each_with_object({}) do |pair, result|
            key, value = pair.split(KV_SEPARATOR, 2)
            result[decode(key).to_sym] = decode(value) if key && value
          end
        end
      end
    end
  end
end
