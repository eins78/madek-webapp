# React server rendering (SSR) policy and client-rendering fallback for UiHelper#react, used with
# MADEK_PERF_SSR_FALLBACK (see app/helpers/ui_helper.rb).
#
# * If server rendering a component fails, that component is rendered in the browser instead of
#   failing the page: the markup is react-rails' `prerender: false` output (the mount point with
#   its props, no server-rendered children), which the client UJS (app/javascript/ujs/react.js)
#   renders like any other component. Applies to every visitor. The request is flagged with
#   `request.env['madek.ssr_fallback'] = true` so that HTTP caches can skip such a response.
# * MADEK_PERF_SSR_FALLBACK_ANONYMOUS = always (default) | never: with `never`, anonymous visitors
#   get every component client-rendered (no SSR attempt). Visitors and crawlers without
#   JavaScript then see no React content while not signed in, only the Rails-rendered <head> and
#   layout.
module Perf
  module SsrFallbackHelper
    ANONYMOUS_POLICIES = %w(always never).freeze

    def self.anonymous_policy
      policy = MadekPerf.value(:ssr_fallback_anonymous, 'always').to_s.strip.downcase
      return policy if ANONYMOUS_POLICIES.include?(policy)
      warn_unknown_policy(policy)
      'always'
    end

    # once per process and value, not on every component
    def self.warn_unknown_policy(policy)
      @warned ||= {}
      return if @warned[policy]
      @warned[policy] = true
      Rails.logger.warn('[perf] SSR: unknown MADEK_PERF_SSR_FALLBACK_ANONYMOUS=' \
                        "#{policy.inspect}, using 'always'")
    end

    # default for the `prerender` option of UiHelper#react
    def perf_ssr_prerender?
      return false if params.permit(:___norender).present?
      return false if perf_ssr_anonymous_request? &&
                      Perf::SsrFallbackHelper.anonymous_policy == 'never'
      true
    end

    # react-rails' `react_component`, but a failed server render falls back to client rendering
    def perf_react_component(name, props, opts)
      react_component(name, props, opts)
    rescue React::ServerRendering::PrerenderError, ConnectionPool::TimeoutError,
           ExecJS::Error => err
      # PrerenderError: JS error during render (and, with an in-process V8 renderer, a render
      # timeout or V8 out of memory); ConnectionPool::TimeoutError: no free renderer within
      # `server_renderer_timeout`; ExecJS::Error: runtime failures react-rails does not
      # translate (e.g. `node` cannot be spawned, the SSR bundle cannot be loaded)
      raise unless opts[:prerender]
      request.env['madek.ssr_fallback'] = true
      Rails.logger.warn(
        "[perf] SSR #{name}: falling back to client rendering " \
        "(#{err.class}: #{err.message.to_s.lines.first.to_s.strip.truncate(200)})")
      react_component(name, props, opts.merge(prerender: false))
    end

    private

    def perf_ssr_anonymous_request?
      respond_to?(:current_user, true) && current_user.nil?
    end
  end
end
