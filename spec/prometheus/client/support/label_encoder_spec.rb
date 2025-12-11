# frozen_string_literal: true

require 'prometheus/client/support/label_encoder'

RSpec.describe Prometheus::Client::Support::LabelEncoder do
  describe '.encode' do
    it 'encodes simple strings unchanged' do
      expect(described_class.encode('simple')).to eq('simple')
    end

    it 'encodes strings with underscores unchanged' do
      expect(described_class.encode('http_method')).to eq('http_method')
    end

    it 'encodes special characters' do
      expect(described_class.encode('/users')).to eq('%2Fusers')
    end

    it 'encodes equals sign' do
      expect(described_class.encode('a=b')).to eq('a%3Db')
    end

    it 'encodes ampersand' do
      expect(described_class.encode('a&b')).to eq('a%26b')
    end

    it 'encodes UTF-8 characters' do
      expect(described_class.encode('日本語')).to eq('%E6%97%A5%E6%9C%AC%E8%AA%9E')
    end

    it 'truncates long strings to 128 characters' do
      long_string = 'a' * 200
      expect(described_class.encode(long_string).length).to eq(128)
    end
  end

  describe '.decode' do
    it 'decodes simple strings' do
      expect(described_class.decode('simple')).to eq('simple')
    end

    it 'decodes percent-encoded characters' do
      expect(described_class.decode('%2Fusers')).to eq('/users')
    end

    it 'decodes UTF-8 characters' do
      expect(described_class.decode('%E6%97%A5%E6%9C%AC%E8%AA%9E')).to eq('日本語')
    end
  end

  describe '.encode_labels / .decode_labels round-trip' do
    [
      { simple: 'value' },
      { http_method: 'GET' },
      { http_method: 'GET', path: '/users' },
      { my_key: 'my_value' },
      { key_with_underscore: 'value_with_underscore' },
      { a: 'b=c' },
      { a: 'b&c' },
      { method: 'GET', status_code: '200', path: '/api/v1/users' },
    ].each do |labels|
      it "round-trips #{labels.inspect}" do
        encoded = described_class.encode_labels(labels)
        decoded = described_class.decode_labels(encoded)
        expect(decoded).to eq(labels)
      end
    end

    it 'handles empty labels' do
      expect(described_class.encode_labels({})).to eq('default')
      expect(described_class.decode_labels('default')).to eq({})
    end

    it 'handles nil labels' do
      expect(described_class.encode_labels(nil)).to eq('default')
      expect(described_class.decode_labels(nil)).to eq({})
    end
  end

  describe '.encode_labels format' do
    it 'uses = as key-value separator' do
      encoded = described_class.encode_labels({ key: 'value' })
      expect(encoded).to eq('key=value')
    end

    it 'uses & as pair separator' do
      encoded = described_class.encode_labels({ a: '1', b: '2' })
      expect(encoded).to eq('a=1&b=2')
    end

    it 'sorts labels alphabetically' do
      encoded = described_class.encode_labels({ z: '1', a: '2', m: '3' })
      expect(encoded).to eq('a=2&m=3&z=1')
    end
  end
end
