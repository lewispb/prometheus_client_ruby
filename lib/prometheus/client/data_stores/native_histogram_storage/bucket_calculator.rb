# frozen_string_literal: true

module Prometheus
  module Client
    module DataStores
      module NativeHistogramStorage
        # Implements exponential bucket boundary calculations per Prometheus native histogram spec.
        #
        # Schema values range from -4 to +8, determining bucket width:
        # - Lower schema = wider buckets (coarser resolution)
        # - Higher schema = narrower buckets (finer resolution)
        #
        # Base calculation: base = 2^(2^-schema)
        # Bucket boundary: boundary(i) = base^i
        #
        # @see https://prometheus.io/docs/specs/native_histograms/
        class BucketCalculator
          # Precomputed bases for each schema value
          # Base for schema s: 2^(2^-s)
          SCHEMA_BASES = {
            -4 => 2**(2**4),   # 65536.0
            -3 => 2**(2**3),   # 256.0
            -2 => 2**(2**2),   # 16.0
            -1 => 2**(2**1),   # 4.0
            0 => 2**(2**0),    # 2.0
            1 => 2**(2**-1),   # sqrt(2) ~= 1.4142
            2 => 2**(2**-2),   # 4th root of 2 ~= 1.1892
            3 => 2**(2**-3),   # 8th root of 2 ~= 1.0905
            4 => 2**(2**-4),   # 16th root ~= 1.0443
            5 => 2**(2**-5),   # ~= 1.0219
            6 => 2**(2**-6),   # ~= 1.0109
            7 => 2**(2**-7),   # ~= 1.0054
            8 => 2**(2**-8)    # ~= 1.0027
          }.freeze

          VALID_SCHEMAS = (-4..8)

          attr_reader :schema, :base

          # @param schema [Integer] Schema value from -4 to +8
          # @raise [ArgumentError] if schema is out of valid range
          def initialize(schema)
            raise ArgumentError, "Schema must be between -4 and 8, got #{schema}" unless VALID_SCHEMAS.cover?(schema)

            @schema = schema
            @base = SCHEMA_BASES[schema]
            @log_base = Math.log(@base)
          end

          # Calculate the bucket index for a given value.
          #
          # For positive values: returns positive index i where base^(i-1) < value <= base^i
          # For negative values: returns negative index with same magnitude calculation
          # For zero: returns nil (handled separately as zero bucket)
          #
          # @param value [Numeric] The value to calculate bucket index for
          # @return [Array<Symbol, Integer>, nil] [sign, index] or nil for zero
          def bucket_index(value)
            return nil if value.zero? || value.nan? || value.infinite?

            abs_value = value.abs

            # Index calculation: ceil(log_base(value))
            # This gives us the bucket where base^(i-1) < value <= base^i
            index = (Math.log(abs_value) / @log_base).ceil

            # Return sign and index separately for positive/negative bucket tracking
            value.negative? ? [:negative, index] : [:positive, index]
          end

          # Calculate the upper bound of a bucket.
          #
          # @param index [Integer] The bucket index
          # @return [Float] The upper bound (exclusive for lower, inclusive for this bucket)
          def upper_bound(index)
            @base**index
          end

          # Calculate the lower bound of a bucket.
          #
          # @param index [Integer] The bucket index
          # @return [Float] The lower bound (exclusive)
          def lower_bound(index)
            @base**(index - 1)
          end

          # Get the growth factor (ratio between adjacent bucket boundaries).
          #
          # @return [Float] The growth factor
          def growth_factor
            @base
          end

          # Calculate approximate bucket width as a percentage.
          #
          # @return [Float] Approximate percentage width of each bucket
          def bucket_width_percent
            (@base - 1) * 100
          end

          # Merge bucket index when reducing schema (halving resolution).
          # When schema decreases by 1, two adjacent buckets merge.
          #
          # @param old_index [Integer] Index at higher resolution
          # @return [Integer] Index at lower resolution
          def self.merge_index(old_index)
            # When schema decreases by 1, every two buckets merge into one
            # Positive indices: 1,2 -> 1, 3,4 -> 2, etc.
            # Use ceiling division to handle both positive and negative indices
            old_index.positive? ? ((old_index + 1) / 2) : ((old_index - 1) / 2)
          end
        end
      end
    end
  end
end
