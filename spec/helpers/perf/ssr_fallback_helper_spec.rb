# UiHelper#react with MADEK_PERF_SSR_FALLBACK: SSR policy for anonymous visitors
# (MADEK_PERF_SSR_FALLBACK_ANONYMOUS) and the client-rendering fallback, see
# app/helpers/perf/ssr_fallback_helper.rb.
#
# Deliberately DB-free and without spec_helper (which truncates and restores the database before
# every example): only the helper modules are loaded, react-rails' view helper
# (`react_component`) and the request context are stubbed.
# Run with: bundle exec rspec spec/helpers/perf/ssr_fallback_helper_spec.rb
require 'logger'
require 'ostruct'
require 'rails'
require 'action_controller'
require 'execjs'
require 'react/server_rendering'

Rails.logger ||= Logger.new(nil)
class Presenter; end unless defined?(::Presenter)
require_relative '../../../app/lib/madek_perf'
require_relative '../../../app/helpers/perf/ssr_fallback_helper'
require_relative '../../../app/helpers/ui_helper'

RSpec.describe Perf::SsrFallbackHelper do
  let(:view_class) do
    Class.new do
      include UiHelper
      include Perf::SsrFallbackHelper
      attr_reader :params, :current_user, :prerender_calls

      def initialize(params:, current_user:, fail_with: nil)
        @params = ActionController::Parameters.new(params)
        @current_user = current_user
        @fail_with = fail_with
        @prerender_calls = []
      end

      def form_authenticity_token
        'token'
      end

      # memoized: the env flag written by the fallback must be visible afterwards
      def request
        @request ||= OpenStruct.new(original_fullpath: '/entries/1', env: {})
      end

      # stub of react-rails' view helper
      def react_component(name, _props, opts)
        @prerender_calls << opts[:prerender]
        raise @fail_with if opts[:prerender] && @fail_with
        "<div data-react-class=\"#{name}\" prerender=\"#{opts[:prerender]}\"></div>"
      end
    end
  end

  let(:user) { Object.new }

  def view(user: nil, params: {}, fail_with: nil)
    view_class.new(params: params, current_user: user, fail_with: fail_with)
  end

  env_keys = %w(MADEK_PERF_SSR_FALLBACK MADEK_PERF_SSR_FALLBACK_ANONYMOUS)

  around do |example|
    saved = env_keys.map { |k| [k, ENV[k]] }.to_h
    env_keys.each { |k| ENV.delete(k) }
    Perf::SsrFallbackHelper.instance_variable_set(:@warned, nil)
    example.run
  ensure
    saved.each { |k, v| ENV[k] = v }
  end

  def toggle(on, anonymous: nil)
    ENV['MADEK_PERF_SSR_FALLBACK'] = on ? '1' : nil
    ENV['MADEK_PERF_SSR_FALLBACK_ANONYMOUS'] = anonymous
  end

  def prerender_error
    js_err = StandardError.new('boom')
    js_err.set_backtrace([])
    React::ServerRendering::PrerenderError.new('UI.Views.X', '{}', js_err)
  end

  errors = {
    'PrerenderError' => -> { prerender_error },
    'ConnectionPool::TimeoutError' => -> { ConnectionPool::TimeoutError.new('no renderer') },
    'ExecJS::RuntimeError' => -> { ExecJS::RuntimeError.new('node: not found') }
  }

  describe 'toggle off (upstream)' do
    before { toggle(false, anonymous: 'never') }

    it 'server-renders for everyone, ignoring MADEK_PERF_SSR_FALLBACK_ANONYMOUS' do
      [nil, user].each do |u|
        v = view(user: u)
        v.react('Views.X')
        expect(v.prerender_calls).to eq [true]
      end
    end

    it '?___norender disables SSR' do
      v = view(params: { ___norender: '1' })
      v.react('Views.X')
      expect(v.prerender_calls).to eq [false]
    end

    errors.each do |error_name, make_error|
      it "lets #{error_name} propagate (error page) and sets no env flag" do
        error = instance_exec(&make_error)
        v = view(fail_with: error)
        expect { v.react('Views.X') }.to raise_error(error.class)
        expect(v.prerender_calls).to eq [true]
        expect(v.request.env).not_to have_key('madek.ssr_fallback')
      end
    end
  end

  describe 'MADEK_PERF_SSR_FALLBACK_ANONYMOUS (toggle on)' do
    {
      nil => [true, true],
      'always' => [true, true],
      'never' => [false, true],
      'NEVER ' => [false, true],
      'bogus' => [true, true]
    }.each do |policy, (anonymous_prerender, user_prerender)|
      it "#{policy.inspect}: anonymous prerender=#{anonymous_prerender}, " \
         "signed in prerender=#{user_prerender}" do
        toggle(true, anonymous: policy)

        v = view
        v.react('Views.X')
        expect(v.prerender_calls).to eq [anonymous_prerender]
        expect(v.request.env).not_to have_key('madek.ssr_fallback')

        v = view(user: user)
        v.react('Views.X')
        expect(v.prerender_calls).to eq [user_prerender]
      end
    end

    it 'warns once about an unknown value' do
      toggle(true, anonymous: 'bogus')
      logger = instance_double(Logger, warn: nil)
      allow(Rails).to receive(:logger).and_return(logger)
      2.times { view.react('Views.X') }
      expect(logger).to have_received(:warn)
        .with(/\[perf\] SSR: unknown MADEK_PERF_SSR_FALLBACK_ANONYMOUS="bogus"/).once
    end

    it '?___norender disables SSR for everyone' do
      toggle(true, anonymous: 'always')
      [nil, user].each do |u|
        v = view(user: u, params: { ___norender: '1' })
        v.react('Views.X')
        expect(v.prerender_calls).to eq [false]
      end
    end

    it 'an explicit prerender option still wins' do
      toggle(true, anonymous: 'never')
      v = view
      v.react('Views.X', {}, prerender: true)
      expect(v.prerender_calls).to eq [true]
    end
  end

  describe 'fallback to client rendering (toggle on)' do
    errors.each do |error_name, make_error|
      %w(always never).each do |policy|
        it "on #{error_name} (ANONYMOUS=#{policy}), for anonymous and signed-in visitors" do
          toggle(true, anonymous: policy)
          [nil, user].each do |u|
            v = view(user: u, fail_with: instance_exec(&make_error))
            html = nil
            expect { html = v.react('Views.X') }.not_to raise_error
            expect(html).to include('prerender="false"')
            if policy == 'never' && u.nil?
              # no SSR attempt at all: a normal response, not a fallback
              expect(v.prerender_calls).to eq [false]
              expect(v.request.env).not_to have_key('madek.ssr_fallback')
            else
              expect(v.prerender_calls).to eq [true, false]
              expect(v.request.env['madek.ssr_fallback']).to be true
            end
          end
        end
      end
    end

    it 'sets no env flag when server rendering succeeds' do
      toggle(true)
      v = view(user: user)
      expect(v.react('Views.X')).to include('prerender="true"')
      expect(v.request.env).not_to have_key('madek.ssr_fallback')
    end

    it 'logs a warning' do
      toggle(true)
      logger = instance_double(Logger, warn: nil)
      allow(Rails).to receive(:logger).and_return(logger)
      view(fail_with: prerender_error).react('Views.X')
      expect(logger).to have_received(:warn)
        .with(/\[perf\] SSR UI\.Views\.X: falling back to client rendering \(React::ServerRendering::PrerenderError: /)
    end

    it 'does not swallow unrelated errors' do
      toggle(true)
      v = view(fail_with: NoMethodError.new('bug'))
      expect { v.react('Views.X') }.to raise_error(NoMethodError)
      expect(v.request.env).not_to have_key('madek.ssr_fallback')
    end
  end
end
