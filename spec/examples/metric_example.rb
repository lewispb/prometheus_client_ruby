# encoding: UTF-8

shared_examples_for Prometheus::Client::Metric do
  subject { described_class.new(:foo, docstring: 'foo description') }

  describe '.new' do
    it 'returns a new metric' do
      expect(subject).to be_a(Prometheus::Client::Metric)
    end

    it 'raises an exception if a reserved base label is used' do
      exception = Prometheus::Client::LabelSetValidator::ReservedLabelError

      expect do
        described_class.new(:foo,
                            docstring: 'foo docstring',
                            preset_labels: { __name__: 'reserved' })
      end.to raise_exception exception
    end

    it 'raises an exception if the given name is blank' do
      expect do
        described_class.new(nil, docstring: 'foo')
      end.to raise_exception ArgumentError
    end

    it 'raises an exception if docstring is missing' do
      expect do
        described_class.new(:foo, docstring: '')
      end.to raise_exception ArgumentError
    end

    it 'raises an exception if a metric name is not a symbol' do
      expect do
        described_class.new('string', docstring: 'foo')
      end.to raise_exception(ArgumentError, /must be a symbol/)
    end

    it 'raises an exception if a metric name starts with __' do
      expect do
        described_class.new(:__internal, docstring: 'foo')
      end.to raise_exception(ArgumentError, /must not start with __/)
    end

    it 'allows UTF-8 metric names (Prometheus 2.40+)' do
      # These are now valid with UTF-8 support
      [
        :'42startsWithNumber',
        :'abc def',
        :'日本語メトリック',
      ].each do |name|
        expect { described_class.new(name, docstring: 'foo') }.not_to raise_exception
      end
    end
  end

  describe '#type' do
    it 'returns the metric type as symbol' do
      expect(subject.type).to be_a(Symbol)
    end
  end
end
