# frozen_string_literal: true

require 'stringio'
require_relative 'metrics_pb'

module Prometheus
  module Client
    module Formats
      # Protobuf exposition format for Prometheus metrics.
      #
      # This format is required for native histogram scraping.
      # Prometheus must be configured with scrape_protocols including 'PrometheusProto'.
      #
      # @see https://prometheus.io/docs/instrumenting/exposition_formats/
      module Protobuf
        MEDIA_TYPE = 'application/vnd.google.protobuf'
        PROTO_PARAMS = 'proto=io.prometheus.client.MetricFamily;encoding=delimited'
        CONTENT_TYPE = "#{MEDIA_TYPE}; #{PROTO_PARAMS}".freeze

        class << self
          # Marshal all metrics in a registry to protobuf format.
          #
          # @param registry [Registry] Prometheus registry
          # @return [String] Binary protobuf data with length-delimited framing
          def marshal(registry)
            output = StringIO.new
            output.set_encoding(Encoding::BINARY)

            registry.metrics.each do |metric|
              family = build_metric_family(metric)
              write_delimited(output, family) if family
            end

            output.string
          end

          private

          def build_metric_family(metric)
            case metric.type
            in :counter then build_counter_family(metric)
            in :gauge then build_gauge_family(metric)
            in :histogram then build_classic_histogram_family(metric)
            in :summary then build_summary_family(metric)
            in :native_histogram then build_native_histogram_family(metric)
            else nil
            end
          end

          def build_counter_family(metric)
            metrics = metric.values.map do |label_set, value|
              labels = build_labels(label_set)
              Io::Prometheus::Client::Metric.new(
                label: labels,
                counter: Io::Prometheus::Client::Counter.new(value: value.to_f)
              )
            end

            Io::Prometheus::Client::MetricFamily.new(
              name: metric.name.to_s,
              help: metric.docstring.to_s,
              type: :COUNTER,
              metric: metrics
            )
          end

          def build_gauge_family(metric)
            metrics = metric.values.map do |label_set, value|
              labels = build_labels(label_set)
              Io::Prometheus::Client::Metric.new(
                label: labels,
                gauge: Io::Prometheus::Client::Gauge.new(value: value.to_f)
              )
            end

            Io::Prometheus::Client::MetricFamily.new(
              name: metric.name.to_s,
              help: metric.docstring.to_s,
              type: :GAUGE,
              metric: metrics
            )
          end

          def build_classic_histogram_family(metric)
            metrics = metric.values.map do |label_set, bucket_values|
              labels = build_labels(label_set)

              # Build classic histogram buckets
              buckets = bucket_values.map do |le, count|
                next if le == 'sum'

                upper_bound = le == '+Inf' ? Float::INFINITY : le.to_f
                Io::Prometheus::Client::Bucket.new(
                  cumulative_count: count.to_i,
                  upper_bound: upper_bound
                )
              end.compact

              Io::Prometheus::Client::Metric.new(
                label: labels,
                histogram: Io::Prometheus::Client::Histogram.new(
                  sample_count: bucket_values['+Inf'].to_i,
                  sample_sum: bucket_values['sum'].to_f,
                  bucket: buckets
                )
              )
            end

            Io::Prometheus::Client::MetricFamily.new(
              name: metric.name.to_s,
              help: metric.docstring.to_s,
              type: :HISTOGRAM,
              metric: metrics
            )
          end

          def build_summary_family(metric)
            metrics = metric.values.map do |label_set, value|
              labels = build_labels(label_set)
              Io::Prometheus::Client::Metric.new(
                label: labels,
                summary: Io::Prometheus::Client::Summary.new(
                  sample_count: value['count'].to_i,
                  sample_sum: value['sum'].to_f
                )
              )
            end

            Io::Prometheus::Client::MetricFamily.new(
              name: metric.name.to_s,
              help: metric.docstring.to_s,
              type: :SUMMARY,
              metric: metrics
            )
          end

          def build_native_histogram_family(metric)
            metrics = metric.values.map do |label_set, data|
              build_native_histogram_metric(label_set, data)
            end

            Io::Prometheus::Client::MetricFamily.new(
              name: metric.name.to_s,
              help: metric.docstring.to_s,
              type: :HISTOGRAM,
              metric: metrics
            )
          end

          def build_native_histogram_metric(label_set, data)
            labels = build_labels(label_set)
            histogram = build_native_histogram(data)

            Io::Prometheus::Client::Metric.new(
              label: labels,
              histogram: histogram
            )
          end

          def build_native_histogram(data)
            positive_spans = build_spans(data[:positive_spans])
            negative_spans = build_spans(data[:negative_spans])

            # Ensure deltas are arrays of integers
            pos_deltas = Array(data[:positive_deltas]).map(&:to_i)
            neg_deltas = Array(data[:negative_deltas]).map(&:to_i)

            Io::Prometheus::Client::Histogram.new(
              sample_count: data[:sample_count].to_i,
              sample_sum: data[:sample_sum].to_f,
              schema: data[:schema].to_i,
              zero_threshold: data[:zero_threshold].to_f,
              zero_count: data[:zero_count].to_i,
              positive_span: positive_spans,
              positive_delta: pos_deltas,
              negative_span: negative_spans,
              negative_delta: neg_deltas
            )
          end

          def build_spans(spans)
            return [] if spans.nil? || spans.empty?

            spans.map do |span|
              offset, length = case span
                               in { offset:, length: } then [offset, length]
                               else [span.offset, span.length]
                               end
              Io::Prometheus::Client::BucketSpan.new(offset: offset.to_i, length: length.to_i)
            end
          end

          def build_labels(label_set)
            label_set.map do |key, value|
              Io::Prometheus::Client::LabelPair.new(
                name: key.to_s,
                value: value.to_s
              )
            end
          end

          # Write a length-delimited protobuf message.
          # Format: varint(length) + message_bytes
          #
          # @param io [IO] Output stream
          # @param message [Google::Protobuf::MessageExts] Protobuf message
          def write_delimited(io, message)
            encoded = message.to_proto
            write_varint(io, encoded.bytesize)
            io.write(encoded)
          end

          # Write a varint (variable-length integer).
          # Each byte uses 7 bits for data and 1 bit (MSB) as continuation flag.
          #
          # @param io [IO] Output stream
          # @param value [Integer] Value to encode
          def write_varint(io, value)
            while value > 0x7F
              io.putc((value & 0x7F) | 0x80)
              value >>= 7
            end
            io.putc(value & 0x7F)
          end
        end
      end
    end
  end
end
