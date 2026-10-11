require 'spec_helper'

describe Perf::AnonCaches do
  include ActiveSupport::Testing::TimeHelpers

  let(:store) { ActiveSupport::Cache::MemoryStore.new }
  let(:toggle) { nil }
  let(:ttl) { nil }

  around :each do |example|
    saved = ENV.to_h.slice('MADEK_PERF_ANON_CACHES', 'MADEK_PERF_ANON_CACHES_TTL')
    begin
      ENV['MADEK_PERF_ANON_CACHES'] = toggle
      ENV['MADEK_PERF_ANON_CACHES_TTL'] = ttl
      example.run
    ensure
      ENV['MADEK_PERF_ANON_CACHES'] = saved['MADEK_PERF_ANON_CACHES']
      ENV['MADEK_PERF_ANON_CACHES_TTL'] = saved['MADEK_PERF_ANON_CACHES_TTL']
    end
  end

  before(:each) { allow(Rails).to receive(:cache).and_return(store) }

  def fetch_counting(*key_parts, user: nil)
    @calls = (@calls || 0)
    described_class.fetch(:test, *key_parts, user: user) do
      @calls += 1
      "value #{@calls}"
    end
  end

  context 'toggle off (unset)' do
    it 'returns the block value untouched and caches nothing' do
      relation = MediaEntry.where(id: nil)
      expect(described_class.fetch(:test, user: nil) { relation }).to equal relation
      expect(fetch_counting).to eq 'value 1'
      expect(fetch_counting).to eq 'value 2'
      expect(described_class.markup_key('root-list/x', '/')).to be_nil
    end
  end

  %w(1 true YES on).each do |value|
    context "toggle on (#{value})" do
      let(:toggle) { value }

      it 'caches for anonymous visitors' do
        expect(fetch_counting('a')).to eq 'value 1'
        expect(fetch_counting('a')).to eq 'value 1'
        expect(fetch_counting('b')).to eq 'value 2'
      end
    end
  end

  context 'toggle on' do
    let(:toggle) { '1' }

    it 'never caches for logged-in users' do
      user = double('User')
      expect(fetch_counting(user: user)).to eq 'value 1'
      expect(fetch_counting(user: user)).to eq 'value 2'
    end

    it 'keys relations by their SQL' do
      expect(fetch_counting(MediaEntry.where(is_published: true))).to eq 'value 1'
      expect(fetch_counting(MediaEntry.where(is_published: true))).to eq 'value 1'
      expect(fetch_counting(MediaEntry.where(is_published: false))).to eq 'value 2'
    end

    it 'keys by locale' do
      I18n.with_locale(:de) { expect(fetch_counting).to eq 'value 1' }
      I18n.with_locale(:en) { expect(fetch_counting).to eq 'value 2' }
      I18n.with_locale(:de) { expect(fetch_counting).to eq 'value 1' }
    end

    it 'expires after the TTL (default 300 s)' do
      expect(described_class.ttl).to eq 300
      expect(fetch_counting).to eq 'value 1'
      travel(301.seconds) { expect(fetch_counting).to eq 'value 2' }
    end

    it 'builds a markup key from name, path and locale' do
      I18n.with_locale(:en) do
        expect(described_class.markup_key('root-list/catalog', '/explore'))
          .to eq 'perf-anon/react/root-list/catalog//explore/en'
      end
    end
  end

  context 'toggle on, TTL 0' do
    let(:toggle) { '1' }
    let(:ttl) { '0' }

    it 'disables the caches' do
      expect(fetch_counting).to eq 'value 1'
      expect(fetch_counting).to eq 'value 2'
      expect(described_class.markup_key('root-list/x', '/')).to be_nil
    end
  end

  context 'other values' do
    let(:toggle) { 'nope' }

    it 'count as off' do
      expect(fetch_counting).to eq 'value 1'
      expect(fetch_counting).to eq 'value 2'
    end
  end
end
