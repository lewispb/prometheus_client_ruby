# frozen_string_literal: true

require 'prometheus/client/support/label_encoder'
require 'prometheus/client/data_stores/native_histogram_storage/span_delta_codec'

module Prometheus
  module Client
    module DataStores
      class MmapFileStore
        # Aggregates metric data from multiple mmap files at read time.
        #
        # In a multiprocess environment (e.g., Puma with workers), each process
        # writes to its own mmap file. This class scans the mmap directory and
        # merges all files for the same metric/labels into a single result.
        #
        # File naming conventions:
        #   Counters:          {metric_name}__{labels}__{pid}.counter
        #   Gauges:            {metric_name}__{labels}__{pid}.gauge
        #   Histograms:        {metric_name}__{labels}__{pid}.histogram
        #   Summaries:         {metric_name}__{labels}__{pid}.summary
        #   Native Histograms: {metric_name}__{labels}__{pid}.mmap
        #
        class MultiprocessAggregator
          attr_reader :mmap_dir

          def initialize(mmap_dir)
            @mmap_dir = mmap_dir
          end

          # Aggregate all counter data from all counter files.
          # Counters are always summed across processes.
          #
          # @return [Hash<Symbol, Hash>] metric_name => { labels_hash => value }
          def aggregate_all_counters
            return {} unless @mmap_dir && Dir.exist?(@mmap_dir)

            grouped_files = group_mmap_files(".counter")

            result = {}
            grouped_files.each do |(metric_name, labels_key), files|
              result[metric_name] ||= {}
              labels_hash = parse_labels_key(labels_key)
              result[metric_name][labels_hash] = sum_counter_files(files)
            end

            result
          end

          # Aggregate all gauge data from all gauge files.
          #
          # @param aggregation [Symbol] Aggregation mode (:sum, :min, :max, :all, :most_recent)
          # @return [Hash<Symbol, Hash>] metric_name => { labels_hash => value_or_array }
          def aggregate_all_gauges(aggregation = :all)
            return {} unless @mmap_dir && Dir.exist?(@mmap_dir)

            grouped_files = group_mmap_files(".gauge")

            result = {}
            grouped_files.each do |(metric_name, labels_key), files|
              result[metric_name] ||= {}
              labels_hash = parse_labels_key(labels_key)
              result[metric_name][labels_hash] = aggregate_gauge_files(files, aggregation, labels_hash)
            end

            result
          end

          # Aggregate gauges with per-metric aggregation modes.
          #
          # @param gauge_modes [Hash<Symbol, Symbol>] metric_name => aggregation_mode
          # @return [Hash<Symbol, Hash>] metric_name => { labels_hash => value_or_array }
          def aggregate_all_gauges_with_modes(gauge_modes)
            return {} unless @mmap_dir && Dir.exist?(@mmap_dir)

            grouped_files = group_mmap_files(".gauge")

            result = {}
            grouped_files.each do |(metric_name, labels_key), files|
              result[metric_name] ||= {}
              labels_hash = parse_labels_key(labels_key)
              aggregation = gauge_modes[metric_name] || :all
              result[metric_name][labels_hash] = aggregate_gauge_files(files, aggregation, labels_hash)
            end

            result
          end

          # Aggregate all classic histogram data from all histogram files.
          # Histograms are summed across processes (bucket counts are added).
          #
          # @return [Hash<Symbol, Hash>] metric_name => { base_labels => { le => value } }
          def aggregate_all_histograms
            return {} unless @mmap_dir && Dir.exist?(@mmap_dir)

            grouped_files = group_mmap_files(".histogram")

            result = {}
            grouped_files.each do |(metric_name, labels_key), files|
              result[metric_name] ||= {}
              labels_hash = parse_labels_key(labels_key)
              result[metric_name][labels_hash] = sum_histogram_files(files)
            end

            result
          end

          # Aggregate all summary data from all summary files.
          # Summaries are summed across processes.
          #
          # @return [Hash<Symbol, Hash>] metric_name => { base_labels => { quantile => value } }
          def aggregate_all_summaries
            return {} unless @mmap_dir && Dir.exist?(@mmap_dir)

            grouped_files = group_mmap_files(".summary")

            result = {}
            grouped_files.each do |(metric_name, labels_key), files|
              result[metric_name] ||= {}
              labels_hash = parse_labels_key(labels_key)
              result[metric_name][labels_hash] = sum_summary_files(files)
            end

            result
          end

          # Aggregate all native histogram data from all mmap files.
          #
          # @param aggregation [Symbol] Aggregation mode (:sum, :all, :min, :max, :most_recent)
          # @return [Hash<Symbol, Hash>] metric_name => { labels_hash => proto_data }
          def aggregate_all_native_histograms(aggregation = :sum)
            return {} unless @mmap_dir && Dir.exist?(@mmap_dir)

            grouped_files = group_mmap_files(".mmap")

            result = {}
            grouped_files.each do |(metric_name, labels_key), files|
              result[metric_name] ||= {}
              labels_hash = parse_labels_key(labels_key)
              result[metric_name][labels_hash] = aggregate_native_histogram_files(files, aggregation, labels_hash)
            end

            result
          end

          # Clean up stale mmap files from dead processes.
          #
          # @param extensions [Array<String>] File extensions to clean up
          # @return [Array<String>] List of removed files
          def cleanup_stale_files(extensions: %w[.counter .gauge .histogram .summary .mmap])
            return [] unless @mmap_dir && Dir.exist?(@mmap_dir)

            removed = []
            extensions.each do |ext|
              Dir.glob(File.join(@mmap_dir, "*#{ext}")).each do |file|
                pid = extract_pid(file, ext)
                next unless pid

                unless process_alive?(pid)
                  File.delete(file)
                  removed << file
                end
              end
            end
            removed
          end

          private

          def group_mmap_files(extension)
            files = Dir.glob(File.join(@mmap_dir, "*#{extension}"))
            grouped = Hash.new { |h, k| h[k] = [] }

            files.each do |file|
              basename = File.basename(file, extension)
              parts = basename.split("__")

              next if parts.size < 2

              metric_name = Support::LabelEncoder.decode(parts[0]).to_sym
              labels_key = parts[1...-1].join("__")
              labels_key = "default" if labels_key.empty?

              grouped[[metric_name, labels_key]] << file
            end

            grouped
          end

          def sum_counter_files(files)
            total = 0.0

            files.each do |file|
              value = read_counter_file(file)
              total += value if value
            rescue StandardError => e
              warn "Failed to read counter file #{file}: #{e.message}" if $DEBUG
            end

            total
          end

          def aggregate_gauge_files(files, aggregation, base_labels)
            values_with_meta = []

            files.each do |file|
              data = read_gauge_file(file)
              next unless data

              values_with_meta << data
            rescue StandardError => e
              warn "Failed to read gauge file #{file}: #{e.message}" if $DEBUG
            end

            return 0.0 if values_with_meta.empty?

            case aggregation
            when :sum
              values_with_meta.sum { |d| d[:value] }
            when :min
              values_with_meta.map { |d| d[:value] }.min
            when :max
              values_with_meta.map { |d| d[:value] }.max
            when :most_recent
              values_with_meta.max_by { |d| d[:timestamp] }&.fetch(:value, 0.0) || 0.0
            when :all
              values_with_meta.map { |d| { pid: d[:pid], value: d[:value] } }
            else
              raise ArgumentError, "Unknown gauge aggregation mode: #{aggregation}"
            end
          end

          def sum_histogram_files(files)
            merged = {}

            files.each do |file|
              buckets = read_histogram_file(file)
              next unless buckets

              buckets.each do |le, value|
                merged[le] ||= 0.0
                merged[le] += value
              end
            rescue StandardError => e
              warn "Failed to read histogram file #{file}: #{e.message}" if $DEBUG
            end

            merged
          end

          def sum_summary_files(files)
            merged = { "count" => 0.0, "sum" => 0.0 }

            files.each do |file|
              values = read_summary_file(file)
              next unless values

              merged["count"] += values["count"] || 0.0
              merged["sum"] += values["sum"] || 0.0
            rescue StandardError => e
              warn "Failed to read summary file #{file}: #{e.message}" if $DEBUG
            end

            merged
          end

          def aggregate_native_histogram_files(files, aggregation, base_labels)
            histograms_with_meta = []

            files.each do |file|
              data = read_native_histogram_file(file)
              next unless data

              pid = extract_pid(file, ".mmap")
              histograms_with_meta << { data: data, pid: pid, timestamp: data[:timestamp] || 0.0 }
            rescue StandardError => e
              warn "Failed to read mmap file #{file}: #{e.message}" if $DEBUG
            end

            return empty_proto_data if histograms_with_meta.empty?

            case aggregation
            when :sum
              merge_native_histogram_data(histograms_with_meta.map { |h| h[:data] })
            when :min
              histograms_with_meta.min_by { |h| h[:data][:sample_count] }&.fetch(:data) || empty_proto_data
            when :max
              histograms_with_meta.max_by { |h| h[:data][:sample_count] }&.fetch(:data) || empty_proto_data
            when :most_recent
              histograms_with_meta.max_by { |h| h[:timestamp] }&.fetch(:data) || empty_proto_data
            when :all
              histograms_with_meta.map do |h|
                {
                  labels: base_labels.merge(pid: h[:pid]),
                  data: h[:data]
                }
              end
            else
              raise ArgumentError, "Unknown histogram aggregation mode: #{aggregation}"
            end
          end

          def read_counter_file(path)
            return nil unless File.exist?(path) && File.size(path) >= CounterStore::FILE_SIZE

            file = File.open(path, "rb")
            mmap = IO::Buffer.map(file, CounterStore::FILE_SIZE, 0, IO::Buffer::READONLY)

            magic = mmap.get_string(0, 4, Encoding::BINARY)
            return nil unless magic == CounterStore::MAGIC

            mmap.get_value(:F64, 8)
          ensure
            file&.close
          end

          def read_gauge_file(path)
            return nil unless File.exist?(path) && File.size(path) >= GaugeStore::FILE_SIZE

            file = File.open(path, "rb")
            mmap = IO::Buffer.map(file, GaugeStore::FILE_SIZE, 0, IO::Buffer::READONLY)

            magic = mmap.get_string(0, 4, Encoding::BINARY)
            return nil unless magic == GaugeStore::MAGIC

            value = mmap.get_value(:F64, 8)
            timestamp = mmap.get_value(:F64, 16)
            pid = extract_pid(path, ".gauge")

            { value: value, timestamp: timestamp, pid: pid }
          ensure
            file&.close
          end

          def read_histogram_file(path)
            return nil unless File.exist?(path) && File.size(path) >= HistogramStore::HEADER_SIZE

            file = File.open(path, "rb")
            file_size = file.size
            mmap = IO::Buffer.map(file, file_size, 0, IO::Buffer::READONLY)

            magic = mmap.get_string(0, 4, Encoding::BINARY)
            return nil unless magic == HistogramStore::MAGIC

            bucket_count = mmap.get_value(:U32, 8)
            buckets = {}
            pos = HistogramStore::HEADER_SIZE

            bucket_count.times do
              key_len = mmap.get_value(:U32, pos)
              pos += 4

              padded_len = ((key_len + 3) / 4) * 4
              key = mmap.get_string(pos, key_len, Encoding::UTF_8)
              pos += padded_len

              value = mmap.get_value(:F64, pos)
              pos += 16 # value + timestamp

              buckets[key] = value
            end

            buckets
          ensure
            file&.close
          end

          def read_summary_file(path)
            return nil unless File.exist?(path) && File.size(path) >= SummaryStore::FILE_SIZE

            file = File.open(path, "rb")
            mmap = IO::Buffer.map(file, SummaryStore::FILE_SIZE, 0, IO::Buffer::READONLY)

            magic = mmap.get_string(0, 4, Encoding::BINARY)
            return nil unless magic == SummaryStore::MAGIC

            {
              "count" => mmap.get_value(:F64, 8),
              "sum" => mmap.get_value(:F64, 16)
            }
          ensure
            file&.close
          end

          def read_native_histogram_file(path)
            return nil unless File.exist?(path) && File.size(path) >= NativeHistogramStorage::MmapFileStore::HEADER_SIZE

            file = File.open(path, "rb")
            file_size = file.size
            mmap = IO::Buffer.map(file, file_size, 0, IO::Buffer::READONLY)

            magic = mmap.get_string(0, 4, Encoding::BINARY)
            return nil unless magic == NativeHistogramStorage::MmapFileStore::MAGIC

            schema = mmap.get_value(:S32, 8)
            zero_threshold = mmap.get_value(:F64, 12)
            count = mmap.get_value(:U64, 20)
            sum = mmap.get_value(:F64, 28)
            zero_count = mmap.get_value(:U64, 36)
            positive_bucket_count = mmap.get_value(:U32, 44)
            negative_bucket_count = mmap.get_value(:U32, 48)
            timestamp = mmap.get_value(:F64, 52)

            capacity = (file_size - NativeHistogramStorage::MmapFileStore::HEADER_SIZE) / (2 * NativeHistogramStorage::MmapFileStore::BUCKET_SIZE)

            positive_buckets = read_buckets_from_mmap(mmap, NativeHistogramStorage::MmapFileStore::HEADER_SIZE, positive_bucket_count)
            negative_offset = NativeHistogramStorage::MmapFileStore::HEADER_SIZE + (capacity * NativeHistogramStorage::MmapFileStore::BUCKET_SIZE)
            negative_buckets = read_buckets_from_mmap(mmap, negative_offset, negative_bucket_count)

            pos_spans, pos_deltas = NativeHistogramStorage::SpanDeltaCodec.encode(positive_buckets)
            neg_spans, neg_deltas = NativeHistogramStorage::SpanDeltaCodec.encode(negative_buckets)

            {
              sample_count: count,
              sample_sum: sum,
              schema: schema,
              zero_threshold: zero_threshold,
              zero_count: zero_count,
              positive_spans: pos_spans,
              positive_deltas: pos_deltas,
              negative_spans: neg_spans,
              negative_deltas: neg_deltas,
              timestamp: timestamp
            }
          ensure
            file&.close
          end

          def read_buckets_from_mmap(mmap, offset, count)
            buckets = {}
            count.times do |i|
              pos = offset + (i * NativeHistogramStorage::MmapFileStore::BUCKET_SIZE)
              index = mmap.get_value(:S32, pos)
              value = mmap.get_value(:U64, pos + 4)
              buckets[index] = value if value.positive?
            end
            buckets
          end

          def merge_native_histogram_data(data_array)
            return empty_proto_data if data_array.empty?
            return data_array.first if data_array.size == 1

            merged = data_array.first.dup
            data_array[1..].each do |data|
              merged = merge_proto_data(merged, data)
            end
            merged
          end

          def merge_proto_data(a, b)
            codec = NativeHistogramStorage::SpanDeltaCodec

            a_positive = codec.decode(a[:positive_spans], a[:positive_deltas])
            a_negative = codec.decode(a[:negative_spans], a[:negative_deltas])
            b_positive = codec.decode(b[:positive_spans], b[:positive_deltas])
            b_negative = codec.decode(b[:negative_spans], b[:negative_deltas])

            merged_positive = a_positive.merge(b_positive) { |_, v1, v2| v1 + v2 }
            merged_negative = a_negative.merge(b_negative) { |_, v1, v2| v1 + v2 }

            pos_spans, pos_deltas = codec.encode(merged_positive)
            neg_spans, neg_deltas = codec.encode(merged_negative)

            {
              sample_count: a[:sample_count] + b[:sample_count],
              sample_sum: a[:sample_sum] + b[:sample_sum],
              schema: a[:schema],
              zero_threshold: a[:zero_threshold],
              zero_count: a[:zero_count] + b[:zero_count],
              positive_spans: pos_spans,
              positive_deltas: pos_deltas,
              negative_spans: neg_spans,
              negative_deltas: neg_deltas
            }
          end

          def empty_proto_data
            {
              sample_count: 0,
              sample_sum: 0.0,
              schema: Prometheus::Client.config.native_histogram_default_schema,
              zero_threshold: Prometheus::Client.config.native_histogram_default_zero_threshold,
              zero_count: 0,
              positive_spans: [],
              positive_deltas: [],
              negative_spans: [],
              negative_deltas: []
            }
          end

          def parse_labels_key(labels_key)
            Support::LabelEncoder.decode_labels(labels_key).freeze
          end

          def extract_pid(file, extension)
            basename = File.basename(file, extension)
            parts = basename.split("__")
            return nil if parts.empty?

            parts.last
          end

          def process_alive?(worker_id)
            if worker_id.match?(/\A\d+\z/)
              pid = worker_id.to_i
              begin
                Process.kill(0, pid)
                return true
              rescue Errno::ESRCH
                return false
              rescue Errno::EPERM
                return true
              end
            end

            return true if worker_id == Support::PidProvider.worker_pid

            true
          end
        end
      end
    end
  end
end
