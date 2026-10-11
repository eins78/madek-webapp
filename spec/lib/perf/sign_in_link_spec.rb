require 'spec_helper'

describe Perf::SignInLink do
  let(:request) { double('request', path: '/sets/abc', original_fullpath: '/sets/abc?list%5Bpage%5D=2') }

  def with_mode(value)
    old = ENV['MADEK_PERF_SIGN_IN_RETURN_TO']
    ENV['MADEK_PERF_SIGN_IN_RETURN_TO'] = value
    yield
  ensure
    ENV['MADEK_PERF_SIGN_IN_RETURN_TO'] = old
  end

  context 'mode path' do
    it 'links with the request path only' do
      with_mode('path') do
        expect(described_class.for(request, {})[:href]).to eq('/auth/sign-in?return-to=%2Fsets%2Fabc')
      end
    end

    it 'keeps lang' do
      with_mode('path') do
        expect(described_class.for(request, lang: 'en')[:href])
          .to eq('/auth/sign-in?return-to=%2Fsets%2Fabc&lang=en')
      end
    end

    it 'marks the link for crawlers and for the JS handler' do
      with_mode('path') do
        link = described_class.for(request, {})
        expect(link[:rel]).to eq('nofollow')
        expect(link[:data]).to eq('sign-in-return-to' => true)
      end
    end
  end

  context 'mode none' do
    it 'links without return-to' do
      with_mode('none') do
        expect(described_class.for(request, {})[:href]).to eq('/auth/sign-in')
      end
    end

    it 'keeps lang as the only query parameter' do
      with_mode('none') do
        expect(described_class.for(request, lang: 'en')[:href]).to eq('/auth/sign-in?lang=en')
      end
    end
  end
end
