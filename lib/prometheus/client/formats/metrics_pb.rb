# frozen_string_literal: true

# Prometheus client model protobuf definitions
# Loaded from compiled FileDescriptorSet

require "google/protobuf"
require "google/protobuf/descriptor_pb"

module Io
  module Prometheus
    module Client
      # Load the compiled FileDescriptorSet
      DESCRIPTOR_DATA = File.binread(
        File.expand_path("metrics.pb", __dir__)
      ).freeze

      # Parse the FileDescriptorSet
      FILE_DESCRIPTOR_SET = Google::Protobuf::FileDescriptorSet.decode(DESCRIPTOR_DATA)

      # Add each file descriptor to a pool
      DESCRIPTOR_POOL = Google::Protobuf::DescriptorPool.new
      FILE_DESCRIPTOR_SET.file.each do |file_proto|
        DESCRIPTOR_POOL.add_serialized_file(file_proto.to_proto)
      end

      LabelPair = DESCRIPTOR_POOL.lookup("io.prometheus.client.LabelPair").msgclass
      Gauge = DESCRIPTOR_POOL.lookup("io.prometheus.client.Gauge").msgclass
      Counter = DESCRIPTOR_POOL.lookup("io.prometheus.client.Counter").msgclass
      Quantile = DESCRIPTOR_POOL.lookup("io.prometheus.client.Quantile").msgclass
      Summary = DESCRIPTOR_POOL.lookup("io.prometheus.client.Summary").msgclass
      Untyped = DESCRIPTOR_POOL.lookup("io.prometheus.client.Untyped").msgclass
      BucketSpan = DESCRIPTOR_POOL.lookup("io.prometheus.client.BucketSpan").msgclass
      Bucket = DESCRIPTOR_POOL.lookup("io.prometheus.client.Bucket").msgclass
      Histogram = DESCRIPTOR_POOL.lookup("io.prometheus.client.Histogram").msgclass
      Metric = DESCRIPTOR_POOL.lookup("io.prometheus.client.Metric").msgclass
      MetricFamily = DESCRIPTOR_POOL.lookup("io.prometheus.client.MetricFamily").msgclass
      MetricType = DESCRIPTOR_POOL.lookup("io.prometheus.client.MetricType").enummodule
    end
  end
end
