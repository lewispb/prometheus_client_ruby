# encoding: UTF-8

require 'prometheus/client/data_stores/synchronized'

module Prometheus
  module Client
    class Config
      attr_accessor :data_store

      # Optional logger for debugging and error messages
      attr_accessor :logger

      # Optional custom PID provider for worker identification.
      # Should be a callable that returns a string identifier.
      # @example
      #   config.pid_provider = -> { "worker_#{ENV['WORKER_ID']}" }
      attr_accessor :pid_provider

      # Default schema for native histograms (-4 to +8)
      # Higher values = more precision, more buckets
      attr_accessor :native_histogram_default_schema

      # Default zero threshold for native histograms
      # Values with |v| <= zero_threshold go to zero bucket
      attr_accessor :native_histogram_default_zero_threshold

      # Default max buckets before resolution reduction
      attr_accessor :native_histogram_default_max_buckets

      def initialize
        @data_store = Prometheus::Client::DataStores::Synchronized.new
        @pid_provider = nil
        @native_histogram_default_schema = 3
        @native_histogram_default_zero_threshold = 2.938735877055719e-39 # 2^-128
        @native_histogram_default_max_buckets = 160
      end
    end
  end
end
