# Server renderer for react-rails, used with MADEK_PERF_SSR_MINI_RACER (see
# config/initializers/perf_ssr.rb).
#
# Same behaviour as React::ServerRendering::SprocketsRenderer (it inherits from it, including the
# `before_render` hook that injects `FrontendAppConfig.to_js`, see config/application.rb), plus:
#
# * If ExecJS runs on MiniRacer (in-process V8), the JS context is created with a hard execution
#   timeout (MADEK_PERF_SSR_MINI_RACER_TIMEOUT_MS, default 2000 ms). ExecJS' own MiniRacerRuntime
#   cannot pass options to MiniRacer::Context. react-rails' `server_renderer_timeout` is only the
#   timeout for checking out a renderer from the pool; nothing else bounds a single render.
# * A render that runs into the timeout (or V8's heap limit) raises RenderTimeout, a
#   React::ServerRendering::PrerenderError (ExecJS does not translate
#   MiniRacer::ScriptTerminatedError, it would escape as-is), and the V8 context is discarded and
#   re-created lazily, so a terminated or out-of-memory isolate is never reused.
#
# With any other ExecJS runtime (e.g. Node, which spawns one process per render) it behaves
# exactly like SprocketsRenderer.
module Perf
  class MadekSsrRenderer < React::ServerRendering::SprocketsRenderer
    DEFAULT_TIMEOUT_MS = 2000

    # raised when a render was terminated by the V8 timeout / memory limit
    class RenderTimeout < React::ServerRendering::PrerenderError; end

    def self.timeout_ms
      Integer(MadekPerf.value(:ssr_mini_racer_timeout_ms, DEFAULT_TIMEOUT_MS))
    end

    def self.mini_racer?
      ::ExecJS.runtime.is_a?(::ExecJS::MiniRacerRuntime)
    end

    # ExecJS' MiniRacer context, but with MiniRacer::Context options (timeout).
    # NOTE: the timeout also applies to evaluating the SSR bundle when the context is created, so
    # it must be well above that (values below ~500 ms make requests pay for failed compiles).
    class TimedMiniRacerContext < ::ExecJS::MiniRacerRuntime::Context
      def initialize(_runtime, source, context_options)
        source = encode(source)
        @context = ::MiniRacer::Context.new(**context_options)
        begin
          translate { @context.eval(source) }
        rescue ::MiniRacer::ScriptTerminatedError, ::MiniRacer::V8OutOfMemoryError => err
          dispose
          # an ExecJS::Error, like any other failure to set up the JS context
          raise ::ExecJS::RuntimeError,
                "SSR bundle could not be loaded (#{err.class}: #{err.message}), " \
                "timeout: #{context_options[:timeout].inspect} ms"
        end
      end

      def dispose
        @context.dispose
      rescue StandardError
        nil
      end
    end

    def initialize(options = {})
      return super unless self.class.mini_racer?

      # same as SprocketsRenderer#initialize + ExecJSRenderer#initialize, except for how the
      # ExecJS context is created
      @replay_console = options.fetch(:replay_console, true)
      @options = options
      @timeout_ms = self.class.timeout_ms
      @context = build_timed_context
    end

    def render(component_name, props, prerender_options)
      @context ||= build_timed_context if @timeout_ms
      super
    rescue *terminating_errors => err
      discard_context!
      raise RenderTimeout.new(component_name, '(props omitted)', err)
    end

    private

    # (resolved lazily: MiniRacer is not loaded when running on Node)
    def terminating_errors
      return [] unless defined?(::MiniRacer::ScriptTerminatedError)
      [::MiniRacer::ScriptTerminatedError, ::MiniRacer::V8OutOfMemoryError]
    end

    def build_timed_context
      js_code = CONSOLE_POLYFILL.dup
      js_code << TIMEOUT_POLYFILL.dup
      js_code << @options.fetch(:code, '')
      @options.fetch(:files, ['react-server.js', 'components.js']).each do |filename|
        js_code << asset_container.find_asset(filename)
      end
      TimedMiniRacerContext.new(
        ::ExecJS.runtime, GLOBAL_WRAPPER + js_code, timeout: @timeout_ms)
    end

    def discard_context!
      ctx = @context
      @context = nil
      ctx.dispose if ctx.respond_to?(:dispose)
    end
  end
end
