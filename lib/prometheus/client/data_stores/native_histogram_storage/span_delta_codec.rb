# frozen_string_literal: true

module Prometheus
  module Client
    module DataStores
      module NativeHistogramStorage
        # Immutable representation of a contiguous range of populated buckets.
        # Used in native histogram span/delta encoding.
        Span = Data.define(:offset, :length) do
          def to_h = { offset:, length: }
        end

        # Encodes and decodes native histogram bucket data between sparse bucket
        # maps and the span/delta format used in protobuf serialization.
        #
        # Span/delta encoding efficiently represents sparse bucket distributions:
        # - Spans describe contiguous ranges of populated bucket indices
        # - Deltas are delta-encoded counts for consecutive buckets
        #
        # @example
        #   buckets = { 0 => 5, 1 => 3, 5 => 2, 6 => 4 }
        #   spans, deltas = SpanDeltaCodec.encode(buckets)
        #   # spans = [Span(offset: 0, length: 2), Span(offset: 3, length: 2)]
        #   # deltas = [5, -2, 2, 2]
        #
        # @see https://prometheus.io/docs/specs/native_histograms/
        module SpanDeltaCodec
          module_function

          # Encode a bucket map to spans and deltas.
          #
          # @param buckets [Hash<Integer, Integer>] bucket_index => count
          # @return [Array<Array<Span>, Array<Integer>>] [spans, deltas]
          def encode(buckets)
            return [[], []] if buckets.empty?

            sorted_indices = buckets.keys.sort
            spans = []
            deltas = []
            prev_count = 0
            span_end = 0
            i = 0

            while i < sorted_indices.length
              start_index = sorted_indices[i]
              length = 1

              # Find consecutive bucket indices
              length += 1 while i + length < sorted_indices.length &&
                                sorted_indices[i + length] == start_index + length

              # Offset is relative to end of previous span
              spans << Span.new(offset: start_index - span_end, length:)
              span_end = start_index + length

              # Delta-encode counts for this span
              length.times do |j|
                count = buckets[sorted_indices[i + j]]
                deltas << (count - prev_count)
                prev_count = count
              end

              i += length
            end

            [spans, deltas]
          end

          # Decode spans and deltas back to a bucket map.
          #
          # @param spans [Array<Span, Hash>] Span objects or hashes with :offset/:length
          # @param deltas [Array<Integer>] Delta-encoded counts
          # @return [Hash<Integer, Integer>] bucket_index => count
          def decode(spans, deltas)
            return {} if spans.nil? || spans.empty? || deltas.nil? || deltas.empty?

            counts = {}
            delta_idx = 0
            bucket_idx = 0
            prev_count = 0

            spans.each do |span|
              span_offset, span_length = case span
                                         in { offset:, length: } then [offset, length]
                                         in Span then [span.offset, span.length]
                                         else [span.offset, span.length]
                                         end

              bucket_idx += span_offset

              span_length.times do
                break if delta_idx >= deltas.length

                count = prev_count + deltas[delta_idx]
                counts[bucket_idx] = count
                prev_count = count
                delta_idx += 1
                bucket_idx += 1
              end
            end

            counts
          end
        end
      end
    end
  end
end
