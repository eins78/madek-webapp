require 'spec_helper'

# MADEK_PERF_DONT_CACHE_PRESENTATION_PARAMS, see
# app/controllers/concerns/perf/presentation_params.rb and the format contract
# at the top of app/javascript/perf/presentation-fragment.js.
#
# The concern is included at boot only when the toggle is on. This spec
# includes it itself (it is inert while the ENV toggle is off, checked per
# request), so it runs with or without the toggle set at boot.
PERF_P_INCLUDED_AT_BOOT = ApplicationController.include?(Perf::PresentationParams)
PERF_P_ON_AT_BOOT = MadekPerf.on?(:dont_cache_presentation_params)

describe 'Perf::PresentationParams', type: :request do
  toggle = 'MADEK_PERF_DONT_CACHE_PRESENTATION_PARAMS'
  html = { 'Accept' => 'text/html' }

  before(:all) do
    unless ApplicationController.include?(Perf::PresentationParams)
      ApplicationController.include(Perf::PresentationParams)
    end
  end

  before(:each) { AppSetting.first || create(:app_setting) }

  around(:each) do |example|
    old = ENV[toggle]
    ENV[toggle] = example.metadata.fetch(:toggle, '1')
    example.run
  ensure
    old.nil? ? ENV.delete(toggle) : ENV[toggle] = old
  end

  def set_cookie_header
    Array(response.headers['Set-Cookie']).join("\n")
  end

  def list_cookie
    set_cookie_header.split("\n").find { |c| c.start_with?('madek_list=') }
  end

  it 'is included at boot exactly when the toggle is on' do
    expect(PERF_P_INCLUDED_AT_BOOT).to eq PERF_P_ON_AT_BOOT
  end

  context 'toggle on, anonymous HTML request' do
    it 'redirects presentation params into the fragment and sets the cookie' do
      get '/entries?list%5Blayout%5D=list&list%5Bpage%5D=2&list%5Bshow_filter%5D=true',
          headers: html
      expect(response.status).to eq 302
      expect(response.headers['Location']).to eq \
        '/entries?list%5Bpage%5D=2#list%5Blayout%5D=list&list%5Bshow_filter%5D=true'
      expect(response.headers['Cache-Control']).to eq 'no-store'
      cookie = list_cookie
      expect(cookie).to start_with \
        'madek_list=list%5Blayout%5D%3Dlist%26list%5Bshow_filter%5D%3Dtrue;'
      expect(cookie).to match(/;\s*path=\/(;|\z)/i)
      expect(cookie).to match(/;\s*max-age=2592000(;|\z)/i)
      expect(cookie).to match(/;\s*samesite=lax(;|\z)/i)
      expect(cookie).not_to match(/httponly/i)
      expect(cookie).not_to match(/;\s*secure(;|\z)/i) # plain http in the test
    end

    it 'canonicalises brackets, keeps other params in order, last value wins' do
      get '/entries?lang=de&list%5blayout%5d=grid&list%5Baccordion%5D=%7B%7D' \
          '&list%5Bfilter%5D=%7B%7D&list%5Blayout%5D=tiles', headers: html
      expect(response.status).to eq 302
      expect(response.headers['Location']).to eq \
        '/entries?lang=de&list%5Bfilter%5D=%7B%7D' \
        '#list%5Blayout%5D=tiles&list%5Baccordion%5D=%7B%7D'
      expect(list_cookie).to start_with \
        'madek_list=list%5Blayout%5D%3Dtiles%26list%5Baccordion%5D%3D%257B%257D;'
    end

    it 'redirects HEAD requests as well' do
      head '/entries?list%5Bshow_filter%5D=true', headers: html
      expect(response.status).to eq 302
      expect(response.headers['Location']).to eq '/entries#list%5Bshow_filter%5D=true'
    end

    it 'writes no cookie for invalid values but still redirects' do
      get '/entries?list%5Blayout%5D=bogus', headers: html
      expect(response.status).to eq 302
      expect(response.headers['Location']).to eq '/entries#list%5Blayout%5D=bogus'
      expect(list_cookie).to be_nil
    end

    it 'does not redirect a request without presentation params' do
      get '/entries?list%5Bpage%5D=1', headers: html
      expect(response.status).to eq 200
      expect(list_cookie).to be_nil
    end

    it 'never redirects JSON requests' do
      get '/entries?list%5Blayout%5D=list', headers: { 'Accept' => 'application/json' }
      expect(response).not_to be_redirect
    end

    it 'never redirects ___sparse requests' do
      get '/entries?list%5Blayout%5D=list&___sparse=%7B%22resources%22%3A%7B%7D%7D',
          headers: html
      expect(response).not_to be_redirect
    end

    it 'never redirects when the auth session cookie is present' do
      get '/entries?list%5Blayout%5D=list',
          headers: html.merge('Cookie' => 'madek-session=not-a-valid-token')
      expect(response).not_to be_redirect
      expect(response.status).to eq 200
      expect(list_cookie).to be_nil
    end

    it 'never redirects when an Authorization header is present' do
      get '/entries?list%5Blayout%5D=list',
          headers: html.merge('Authorization' => 'token not-a-valid-token')
      expect(response).not_to be_redirect
    end

    it 'never redirects when the Varnish variant already applied the cookie' do
      get '/entries?list%5Blayout%5D=list',
          headers: html.merge('X-Madek-List-Cookie' => 'list%5Blayout%5D=list')
      expect(response.status).to eq 200
    end
  end

  context 'toggle on, preference cookie (no-JS visitors)' do
    def get_with_cookie(value, path = '/entries')
      # `html` is a block-local of the describe body, not visible inside `def`
      get path, headers: { 'Accept' => 'text/html', 'Cookie' => "madek_list=#{value}" }
    end

    it 'renders with the cookie presentation, private, without Set-Cookie' do
      get_with_cookie('list%5Blayout%5D%3Dlist%26list%5Bshow_filter%5D%3Dtrue',
                      '/entries?list%5Bpage%5D=1')
      expect(response.status).to eq 200
      expect(controller.params[:list][:layout]).to eq 'list'
      expect(controller.params[:list][:show_filter]).to eq 'true'
      expect(controller.params[:list][:page]).to eq '1'
      expect(request.query_parameters['list']['layout']).to eq 'list'
      expect(response.headers['Cache-Control']).to include 'private'
      expect(response.headers['Cache-Control']).not_to include 'public'
      expect(list_cookie).to be_nil
    end

    it 'accepts a valid accordion and drops an invalid one' do
      get_with_cookie('list%5Blayout%5D%3Dtiles%26list%5Baccordion%5D%3D%257B%257D')
      expect(controller.params[:list][:accordion]).to eq '{}'
      get_with_cookie('list%5Blayout%5D%3Dtiles%26list%5Baccordion%5D%3Dnot-json')
      expect(response.status).to eq 200
      expect(controller.params[:list][:layout]).to eq 'tiles'
      expect(controller.params[:list]).not_to have_key(:accordion)
    end

    it 'ignores a cookie with a foreign key' do
      get_with_cookie('list%5Blayout%5D%3Dlist%26list%5Bfilter%5D%3D%257B%257D')
      expect(response.status).to eq 200
      expect(controller.params[:list]).to be_nil
    end

    it 'ignores the cookie for JSON requests' do
      get '/entries', headers: { 'Accept' => 'application/json',
                                 'Cookie' => 'madek_list=list%5Blayout%5D%3Dlist' }
      expect(controller.params[:list]).to be_nil
    end
  end

  context 'toggle off', toggle: '0' do
    it 'renders presentation params without redirect or cookie' do
      get '/entries?list%5Blayout%5D=list', headers: html
      expect(response.status).to eq 200
      expect(controller.params[:list][:layout]).to eq 'list'
      expect(list_cookie).to be_nil
    end

    it 'does not read the cookie' do
      get '/entries', headers: html.merge('Cookie' => 'madek_list=list%5Blayout%5D%3Dlist')
      expect(response.status).to eq 200
      expect(controller.params[:list]).to be_nil
    end
  end
end
