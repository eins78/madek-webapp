require 'spec_helper'

# MADEK_PERF_ANON_HTTP_CACHE, see app/controllers/concerns/perf/anon_http_cache.rb
#
# The toggle is read when ApplicationController loads, so it cannot be flipped per example: run this file
# once without and once with the toggle; each run executes one of the two contexts.
#
#   bundle exec rspec spec/requests/perf/anon_http_cache_spec.rb
#   MADEK_PERF_ANON_HTTP_CACHE=1 bundle exec rspec spec/requests/perf/anon_http_cache_spec.rb
#
# NOTE: run on its own or before controller specs. After the controller examples of
# spec/controllers/application_controller_spec.rb (rspec-rails' empty-template view stubbing) request specs
# in the same process get empty bodies with `Cache-Control: no-cache` -- independent of this feature.
describe 'MADEK_PERF_ANON_HTTP_CACHE: anonymous HTTP cache headers', type: :request do
  let(:public_cc) do
    'max-age=0, public, stale-while-revalidate=86400, stale-if-error=86400, s-maxage=600'
  end
  let(:private_cc) { 'max-age=0, private, must-revalidate' }
  let(:html) { { 'Accept' => 'text/html' } }
  let(:json) { { 'Accept' => 'application/json' } }

  before do
    AppSetting.first || create(:app_setting)
  end

  # like production (test env disables it, and with it the csrf meta tag)
  around do |example|
    ActionController::Base.allow_forgery_protection = true
    example.run
  ensure
    ActionController::Base.allow_forgery_protection = false
  end

  def sign_in(user)
    auth_system = AuthSystem.find_by(id: 'password') || create(:auth_system)
    session = UserSession.create!(user: user, auth_system: auth_system)
    cookies[Madek::Constants::MADEK_SESSION_COOKIE_NAME] = session.token
  end

  def csrf_meta?
    response.body.include?('name="csrf-token"')
  end

  def sets_cookie?
    response.headers['Set-Cookie'].present?
  end

  def patch_list_config
    patch '/session/list_config',
          params: { list_config: { layout: 'tiles' } }.to_json,
          headers: json.merge('Content-Type' => 'application/json')
  end

  context 'toggle off (default = upstream)', if: !MadekPerf.on?(:anon_http_cache) do
    it 'does not load the concern or the middleware' do
      expect(ApplicationController.ancestors.map(&:name)).not_to include('Perf::AnonHttpCache')
      expect(Rails.application.middleware.map(&:name)).not_to include('Perf::PublicCacheSetCookieGuard')
    end

    it 'anonymous HTML stays private and gets a CSRF token + session cookie' do
      get '/search', headers: html
      expect(response.status).to eq 200
      expect(response.headers['Cache-Control']).to eq private_cc
      expect(csrf_meta?).to be true
      expect(response.body).not_to include('authToken&quot;:null')
      expect(sets_cookie?).to be true
    end

    it 'anonymous 404 keeps no-store and the render timestamp' do
      get "/entries/#{SecureRandom.uuid}", headers: html
      expect(response.status).to eq 404
      expect(response.headers['Cache-Control']).to eq 'no-store'
      expect(response.body).to match(/class=['"]title-xs['"]>\d{4}-\d\d-\d\d /)
    end

    it 'anonymous PATCH /session/list_config without a token is rejected (as before)' do
      patch_list_config
      expect(response.status).to eq 422
    end
  end

  context 'toggle on', if: MadekPerf.on?(:anon_http_cache) do
    it 'loads the concern and the middleware' do
      expect(ApplicationController.ancestors).to include(Perf::AnonHttpCache)
      expect(Rails.application.middleware.map(&:name)).to include('Perf::PublicCacheSetCookieGuard')
    end

    it 'anonymous HTML is public for shared caches, without token and cookie' do
      get '/search', headers: html
      expect(response.status).to eq 200
      expect(response.headers['Cache-Control']).to eq public_cc
      expect(response.headers['Vary']).to include 'Accept'
      expect(response.headers['Vary']).not_to include 'Cookie'
      expect(response.headers['X-Madek-SSR-Fallback']).to be_nil
      expect(csrf_meta?).to be false
      expect(response.body).to include('authToken&quot;:null')
      expect(response.body).not_to include('name="authenticity_token"')
      expect(sets_cookie?).to be false
    end

    it 'identical anonymous requests get byte-identical bodies' do
      get '/search', headers: html
      first_body = response.body
      expect(sets_cookie?).to be false
      cookies.delete(Madek::Constants::Webapp::SESSION_NAME)
      get '/search', headers: html
      expect(response.body).to eq first_body
    end

    context 'with MADEK_PERF_ANON_HTTP_CACHE_S_MAXAGE=60' do
      around do |example|
        ENV['MADEK_PERF_ANON_HTTP_CACHE_S_MAXAGE'] = '60'
        example.run
      ensure
        ENV.delete('MADEK_PERF_ANON_HTTP_CACHE_S_MAXAGE')
      end

      it 'uses the knob (read per request)' do
        get '/search', headers: html
        expect(response.headers['Cache-Control']).to include 's-maxage=60'
        expect(response.headers['Cache-Control']).to include 'public'
      end
    end

    it 'anonymous JSON is public' do
      get '/entries', headers: json
      expect(response.status).to eq 200
      expect(response.media_type).to eq 'application/json'
      expect(response.headers['Cache-Control']).to eq public_cc
      expect(sets_cookie?).to be false
    end

    it 'anonymous 404 is public without timestamp, 401 is no-store, neither sets a cookie' do
      get "/entries/#{SecureRandom.uuid}", headers: html
      expect(response.status).to eq 404
      expect(response.headers['Cache-Control']).to eq public_cc
      expect(response.body).not_to match(/class=['"]title-xs['"]>\d{4}-\d\d-\d\d /)
      expect(sets_cookie?).to be false

      get '/my', headers: html
      expect(response.status).to eq 401
      expect(response.headers['Cache-Control']).to eq 'no-store'
      expect(sets_cookie?).to be false
    end

    it 'confidential link tokens are never stored' do
      get '/search?accessToken=foo', headers: html
      expect(response.headers['Cache-Control']).to eq 'no-store'
      expect(sets_cookie?).to be false
    end

    it 'a page whose SSR fell back to client rendering (option D) is never stored' do
      get '/search', headers: html, env: { 'madek.ssr_fallback' => true }
      expect(response.status).to eq 200
      expect(response.headers['X-Madek-SSR-Fallback']).to eq '1'
      expect(response.headers['Cache-Control']).to include 'no-store'
      expect(response.headers['Cache-Control']).not_to include 'public'
      expect(sets_cookie?).to be false
    end

    it 'a request with an old session cookie (session gets loaded) stays private' do
      # obtain a real `_madek_session` cookie like every visitor before the switch: test_auth keeps its
      # token (KEEP_CSRF_TOKEN), so its page writes the session
      get '/auth/sign-in', headers: html
      expect(csrf_meta?).to be true
      expect(sets_cookie?).to be true
      # the flash partial reads the session -> loaded -> re-sent as Set-Cookie -> must not be public
      get '/search', headers: html
      expect(response.status).to eq 200
      expect(csrf_meta?).to be false
      expect(response.headers['Cache-Control']).to eq private_cc
    end

    it 'logged-in requests are unchanged (private, real CSRF token)' do
      sign_in(create(:user))
      get '/search', headers: html
      expect(response.status).to eq 200
      expect(response.headers['Cache-Control']).to eq private_cc
      expect(csrf_meta?).to be true
      expect(response.body).not_to include('authToken&quot;:null')
    end

    it 'anonymous no-op PATCH /session/list_config works without a token' do
      patch_list_config
      expect(response.status).to be < 400
    end

    it 'signed-in PATCH /session/list_config without a token is still rejected' do
      sign_in(create(:user))
      patch_list_config
      expect(response.status).to eq 422
    end

    it 'anonymous POSTs elsewhere still require a CSRF token' do
      post "/entries/#{SecureRandom.uuid}/checksum/generate", headers: json
      expect(response.status).to eq 422
    end

    describe 'Perf::PublicCacheSetCookieGuard' do
      it 'downgrades a public response that sets a cookie' do
        app = ->(_env) { [200, { 'Cache-Control' => 'public, s-maxage=600', 'Set-Cookie' => 'a=b' }, ['x']] }
        _status, headers, _body = Perf::PublicCacheSetCookieGuard.new(app).call({})
        expect(headers['Cache-Control']).to eq private_cc
      end

      it 'leaves public responses without cookies alone' do
        app = ->(_env) { [200, { 'Cache-Control' => 'public, s-maxage=600' }, ['x']] }
        _status, headers, _body = Perf::PublicCacheSetCookieGuard.new(app).call({})
        expect(headers['Cache-Control']).to eq 'public, s-maxage=600'
      end
    end
  end
end
