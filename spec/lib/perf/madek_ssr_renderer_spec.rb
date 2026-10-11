# Perf::MadekSsrRenderer on MiniRacer (MADEK_PERF_SSR_MINI_RACER): render timeout and isolate
# rebuild.
#
# Deliberately DB-free and without spec_helper (which truncates and restores the database before
# every example): only react-rails' renderer classes are loaded, and the renderer gets a tiny stub
# "bundle" (`code:`, no asset `files:`), so neither Sprockets nor a Rails app is needed. Skipped
# when mini_racer cannot be loaded on this host.
#
# Runs V8 in single-threaded mode (the production default with the toggle on) unless
# MADEK_PERF_SSR_MINI_RACER_V8_THREADS is set; run it once in each mode:
#   bundle exec rspec spec/lib/perf/madek_ssr_renderer_spec.rb
#   MADEK_PERF_SSR_MINI_RACER_V8_THREADS=1 bundle exec rspec spec/lib/perf/madek_ssr_renderer_spec.rb
require 'active_support'
require 'active_support/core_ext/object/blank'
require 'active_support/core_ext/string/output_safety'
require 'execjs'
require 'react/server_rendering'
require_relative '../../../app/lib/madek_perf'
require_relative '../../../app/lib/perf/madek_ssr_renderer'

MINI_RACER_LOAD_ERROR =
  begin
    require 'mini_racer'
    nil
  rescue LoadError => e
    e.message
  end

RSpec.describe Perf::MadekSsrRenderer,
               skip: MINI_RACER_LOAD_ERROR && "mini_racer cannot be loaded: #{MINI_RACER_LOAD_ERROR}" do
  # stub "SSR bundle": the two globals react-rails' ExecJSRenderer calls, and two components
  let(:stub_bundle) do
    <<-JS
      var React = { createElement: function (type, props) { return { type: type, props: props }; } };
      var ReactDOMServer = {
        renderToString: function (el) { return el.type(el.props); },
        renderToStaticMarkup: function (el) { return el.type(el.props); }
      };
      var Hello = function (props) { return '<p>Hello ' + props.name + '</p>'; };
      var Forever = function () { while (true) {} };
    JS
  end

  timeout_env = 'MADEK_PERF_SSR_MINI_RACER_TIMEOUT_MS'

  # (before/after(:all) also run for a skipped group; MiniRacer is only partly defined then)
  before(:all) do
    next if MINI_RACER_LOAD_ERROR
    @previous_runtime = ExecJS.runtime
    unless MadekPerf.on?(:ssr_mini_racer_v8_threads)
      begin
        MiniRacer::Platform.set_flags!(:single_threaded)
      rescue MiniRacer::PlatformAlreadyInitialized
        warn 'V8 platform already initialised, single_threaded mode not applied'
      end
    end
    ExecJS.runtime = ExecJS::Runtimes::MiniRacer
  end

  after(:all) { ExecJS.runtime = @previous_runtime if @previous_runtime }

  around do |example|
    previous = ENV[timeout_env]
    example.run
  ensure
    ENV[timeout_env] = previous
  end

  def renderer(code: stub_bundle)
    described_class.new(code: code, files: [], replay_console: false)
  end

  def now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  it 'runs on MiniRacer with the default timeout of 2000 ms' do
    ENV.delete(timeout_env)
    expect(described_class.mini_racer?).to be true
    expect(described_class.timeout_ms).to eq 2000
  end

  it 'renders a component' do
    html = renderer.render('Hello', { name: 'World' }, true)
    expect(html).to eq '<p>Hello World</p>'
    expect(html).to be_html_safe
  end

  it 'raises RenderTimeout (a PrerenderError) after about the timeout, ' \
     'then rebuilds the isolate and renders again' do
    ENV[timeout_env] = '300'
    r = renderer
    error = nil
    t0 = now
    begin
      r.render('Forever', {}, true)
    rescue StandardError => e
      error = e
    end
    seconds = now - t0
    expect(error).to be_a(described_class::RenderTimeout)
    expect(error).to be_a(React::ServerRendering::PrerenderError)
    expect(error.message).to include('Forever')
    expect(seconds).to be_between(0.25, 3.0)

    expect(r.render('Hello', { name: 'again' }, true)).to eq '<p>Hello again</p>'
  end

  it 'reports a timeout while loading the bundle as ExecJS::RuntimeError, ' \
     'not as a raw MiniRacer error' do
    ENV[timeout_env] = '1'
    # a bundle that never finishes loading (a real bundle takes far longer than 1 ms to compile,
    # the stub one would not)
    expect { renderer(code: stub_bundle + "\nwhile (true) {}\n") }
      .to raise_error(ExecJS::RuntimeError, /SSR bundle could not be loaded \(MiniRacer::ScriptTerminatedError/)
  end

  it 'still raises a PrerenderError for a JavaScript error' do
    expect { renderer.render('NoSuchComponent', {}, true) }
      .to raise_error(React::ServerRendering::PrerenderError, /NoSuchComponent/)
  end
end
