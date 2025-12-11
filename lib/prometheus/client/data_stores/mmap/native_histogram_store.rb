# frozen_string_literal: true

require_relative '../native_histogram_storage/sparse_bucket_store'

module Prometheus
  module Client
    module DataStores
      class MmapFileStore
        # Mmap-backed store for native histogram metrics.
        #
        # Native histograms use exponential buckets stored with spans and deltas.
        # This enables much more efficient storage than classic histograms.
        #
        # Uses SparseBucketStore which handles the mmap file format:
        #   - 64-byte header with schema, counts, etc.
        #   - Dynamic bucket storage for positive and negative values
        #
        class NativeHistogramStore
          attr_reader :metric_name, :store_settings

          def initialize(metric_name:, store_settings:, metric_settings:)
            @metric_name = metric_name
            @store_settings = store_settings
            @metric_settings = metric_settings
            @values_aggregation_mode = metric_settings[:aggregation]
            @schema = metric_settings[:schema] || Prometheus::Client.config.native_histogram_default_schema
            @zero_threshold = metric_settings[:zero_threshold] || Prometheus::Client.config.native_histogram_default_zero_threshold
            @max_buckets = metric_settings[:max_buckets] || Prometheus::Client.config.native_histogram_default_max_buckets

            @stores = {}
            @store_opened_by_pid = nil
            @lock = Monitor.new
          end

          def synchronize
            @lock.synchronize { yield }
          end

          def observe(labels:, value:)
            @lock.synchronize do
              store_for(labels).observe(value)
            end
          end

          def get(labels:)
            @lock.synchronize do
              store = @stores[store_key(labels)]
              store&.to_proto_data
            end
          end

          def set(labels:, val:)
            # Native histograms don't support set - they only observe
            raise NotImplementedError, "Native histograms don't support set, use observe"
          end

          def increment(labels:, by: 1)
            # Native histograms don't support increment - they only observe
            raise NotImplementedError, "Native histograms don't support increment, use observe"
          end

          def init_label_set(labels:)
            @lock.synchronize do
              store_for(labels)
            end
          end

          def all_values
            aggregator = MultiprocessAggregator.new(@store_settings[:dir])

            case @values_aggregation_mode
            when MmapFileStore::SUM
              histograms = aggregator.aggregate_all_native_histograms(:sum)
              histograms[@metric_name] || {}
            when MmapFileStore::MAX
              histograms = aggregator.aggregate_all_native_histograms(:max)
              histograms[@metric_name] || {}
            when MmapFileStore::MIN
              histograms = aggregator.aggregate_all_native_histograms(:min)
              histograms[@metric_name] || {}
            when MmapFileStore::MOST_RECENT
              histograms = aggregator.aggregate_all_native_histograms(:most_recent)
              histograms[@metric_name] || {}
            when MmapFileStore::ALL
              histograms = aggregator.aggregate_all_native_histograms(:all)
              result = {}
              (histograms[@metric_name] || {}).each do |labels, data_array|
                if data_array.is_a?(Array)
                  data_array.each do |entry|
                    combined_labels = entry[:labels]
                    result[combined_labels] = entry[:data]
                  end
                else
                  result[labels] = data_array
                end
              end
              result
            else
              raise InvalidStoreSettingsError, "Invalid Aggregation Mode: #{@values_aggregation_mode}"
            end
          end

          private

          def store_for(labels)
            key = store_key(labels)

            # Handle process forking - reopen stores if PID changed
            current_pid = worker_pid
            if @store_opened_by_pid != current_pid
              @stores.each_value(&:close)
              @stores.clear
              @store_opened_by_pid = current_pid
            end

            @stores[key] ||= create_store(key, labels)
          end

          def create_store(key, labels)
            filename = generate_filename(labels)
            file_path = File.join(@store_settings[:dir], filename)

            NativeHistogramStorage::SparseBucketStore.new(
              file_path: file_path,
              schema: @schema,
              zero_threshold: @zero_threshold,
              max_buckets: @max_buckets
            )
          end

          def store_key(labels)
            if @values_aggregation_mode == MmapFileStore::ALL
              labels = labels.merge(pid: worker_pid)
            end

            labels.to_a.sort.map { |k, v| "#{k}=#{v}" }.join("&")
          end

          def generate_filename(labels)
            label_part = Support::LabelEncoder.encode_labels(labels)
            metric_part = Support::LabelEncoder.encode(@metric_name)

            "#{metric_part}__#{label_part}__#{worker_pid}.mmap"
          end

          def worker_pid
            Support::PidProvider.worker_pid
          end
        end
      end
    end
  end
end
