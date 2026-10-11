require 'spec_helper'

# MADEK_PERF_SIGN_IN_RETURN_TO: sign-in link of the login menu on an anonymous page.
describe 'sign-in link (MADEK_PERF_SIGN_IN_RETURN_TO)', type: :request do
  def sign_in_tag(html)
    html[/<a[^>]*href=['"]\/auth\/sign-in[^>]*>/]
  end

  def with_mode(value)
    old = ENV['MADEK_PERF_SIGN_IN_RETURN_TO']
    value.nil? ? ENV.delete('MADEK_PERF_SIGN_IN_RETURN_TO') : ENV['MADEK_PERF_SIGN_IN_RETURN_TO'] = value
    yield
  ensure
    old.nil? ? ENV.delete('MADEK_PERF_SIGN_IN_RETURN_TO') : ENV['MADEK_PERF_SIGN_IN_RETURN_TO'] = old
  end

  it 'unset: upstream link with the full path and query, no perf attributes' do
    with_mode(nil) do
      get '/explore?foo=bar'
      tag = sign_in_tag(response.body)
      expect(tag).to include('return-to=%2Fexplore%3Ffoo%3Dbar')
      expect(tag).not_to include('data-sign-in-return-to')
      expect(tag).not_to include('nofollow')
    end
  end

  it 'path: return-to is the path only, nofollow and JS marker present' do
    with_mode('path') do
      get '/explore?foo=bar'
      tag = sign_in_tag(response.body)
      expect(tag).to include('return-to=%2Fexplore"').or include("return-to=%2Fexplore'")
      expect(tag).to include('rel')
      expect(tag).to include('nofollow')
      expect(tag).to include('data-sign-in-return-to')
    end
  end

  it 'none: no return-to' do
    with_mode('none') do
      get '/explore?foo=bar'
      tag = sign_in_tag(response.body)
      expect(tag).not_to include('return-to=')
      expect(tag).to include('data-sign-in-return-to')
    end
  end
end
