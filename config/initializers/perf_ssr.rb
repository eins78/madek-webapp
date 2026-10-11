# React server rendering (SSR): ExecJS runtime selection and, with the toggle on, the
# in-process V8 renderer.
#
# Why this file also runs with the toggle off: `require "execjs"` (Bundler.require) autodetects
# the runtime once, and ExecJS prefers MiniRacer over Node as soon as `require "mini_racer"`
# succeeds (`require: false` in the Gemfile does not prevent that). So the runtime is pinned in
# both states: off = what autodetect would pick without mini_racer (Node), on = MiniRacer.
#
# This runs before app/lib is autoloadable, so `MadekPerf` cannot be used here; ENV is read
# directly with the same rule as `MadekPerf.on?` (1/true/yes/on, case-insensitive = on).

perf_ssr_on = lambda do |name|
  %w(1 true yes on).include?(ENV["MADEK_PERF_#{name}"].to_s.strip.downcase)
end

# upstream runtime: EXECJS_RUNTIME keeps its precedence, else the first available non-deprecated
# runtime except MiniRacer (nil if there is none: then the autodetected runtime stays)
perf_ssr_upstream_runtime = lambda do
  ExecJS::Runtimes.from_environment ||
    ExecJS::Runtimes.runtimes.reject(&:deprecated?)
      .reject { |r| r.is_a?(ExecJS::MiniRacerRuntime) }.find(&:available?)
end

# MADEK_PERF_SSR_MINI_RACER (default off = upstream): render React components in an in-process V8
# (mini_racer) instead of spawning a Node process per component.
# Measured: about −58 % webapp CPU per request in a crawler-weighted benchmark on production-shaped
# data (maintainers' perf notes, 2026-10). Implementation: app/lib/perf/madek_ssr_renderer.rb.
if perf_ssr_on.call('SSR_MINI_RACER')
  # Each pooled renderer holds a V8 isolate with the SSR bundle (tens of MB), so the pool
  # defaults to the number of Puma threads instead of upstream's 12; keep a worker memory limit
  # in place. react-rails copies this setting in its own `after_initialize`, which runs after
  # all initializers (config/environments/production.rb stays untouched).
  Rails.application.config.react.server_renderer_pool_size = Integer(
    ENV['MADEK_PERF_SSR_MINI_RACER_POOL_SIZE'].presence ||
    ENV['RAILS_MAX_THREADS'].presence || ENV['PUMA_MAX_THREADS'].presence || 4)

  v8_mode = 'none'
  begin
    require 'mini_racer'
  rescue LoadError => e
    # loud fallback: keep the site up on the upstream renderer (failing here would put Puma
    # into a restart loop for a performance option)
    runtime = perf_ssr_upstream_runtime.call
    ExecJS.runtime = runtime if runtime
    msg = '[perf] MADEK_PERF_SSR_MINI_RACER is on, but mini_racer cannot be loaded ' \
          "(#{e.message}); server rendering stays on #{ExecJS.runtime.name}"
    Rails.logger.error(msg)
    warn(msg)
  else
    v8_mode = 'threads'
    # Fork safety: V8's default platform does not survive fork() once a context exists in the
    # parent (e.g. a Puma master with `preload_app!`); in single-threaded mode it does, at the cost
    # of about 1-2 ms per render. Opt out with MADEK_PERF_SSR_MINI_RACER_V8_THREADS=1 where the
    # master never renders (no preload). Must be set before the first MiniRacer::Context; the V8
    # platform is initialised lazily on the first context, not by the `require`.
    unless perf_ssr_on.call('SSR_MINI_RACER_V8_THREADS')
      begin
        MiniRacer::Platform.set_flags!(:single_threaded)
        v8_mode = 'single_threaded'
      rescue MiniRacer::PlatformAlreadyInitialized
        Rails.logger.error('[perf] SSR: V8 platform already initialised, ' \
                           'single_threaded mode could not be set')
      end
    end
    if ENV['EXECJS_RUNTIME'].present? && ENV['EXECJS_RUNTIME'] != 'MiniRacer'
      Rails.logger.warn("[perf] SSR: MADEK_PERF_SSR_MINI_RACER is on, ignoring " \
                        "EXECJS_RUNTIME=#{ENV['EXECJS_RUNTIME']}")
    end
    ExecJS.runtime = ExecJS::Runtimes::MiniRacer
  end

  # registered after react-rails' own hook (which sets the renderer and builds the lazy pool),
  # so this runs after it; the renderer behaves exactly like upstream's on any other runtime
  Rails.application.config.after_initialize do
    React::ServerRendering.renderer = Perf::MadekSsrRenderer
    React::ServerRendering.reset_pool
    # WARN, not INFO: production may run with RAILS_LOG_LEVEL=WARN
    Rails.logger.warn(
      "[perf] SSR: ExecJS runtime=#{ExecJS.runtime.name}, " \
      "pool=#{React::ServerRendering.pool_size}, " \
      "timeout=#{Perf::MadekSsrRenderer.mini_racer? ? "#{Perf::MadekSsrRenderer.timeout_ms} ms" : 'none'}, " \
      "v8=#{v8_mode}")
  end
else
  runtime = perf_ssr_upstream_runtime.call
  ExecJS.runtime = runtime if runtime
end
