# MADEK_PERF_ANON_HTTP_CACHE: cache-friendly anonymous (logged-out) responses.
# Included by ApplicationController only when the toggle is on (default off = upstream, this file is unused).
#
# Anonymous GET responses carry no CSRF token and no session cookie, so their bodies are identical for
# identical requests and a shared cache may store them. A cache in front MUST bypass requests carrying the
# `madek-session` cookie (and must not use a quick handler that answers before cookies are seen), otherwise
# signed-in users can get the anonymous copy of a page.
#
# * No token: for anonymous GET/HEAD requests the layout omits the `csrf-token` meta tag and React views get
#   `authToken: null` (`app/views/layouts/_base.haml`, `UiHelper#react`). `form_authenticity_token` is the
#   only thing that writes the Rails session (`_madek_session`) on an anonymous page view, so no `Set-Cookie`.
#   Anonymous pages that make a non-GET request keep their token (KEEP_CSRF_TOKEN). Signed-in requests are
#   unchanged: they always get a real token; sign-in returns with a full page load, which carries one again.
#
# * Public: anonymous GET/HEAD responses with status 200/404 and an HTML/JSON body get
#   `Cache-Control: max-age=0, public, stale-while-revalidate=…, stale-if-error=…, s-maxage=…`
#   Browsers always revalidate (max-age=0, weak ETag -> 304), shared caches may keep it for `s-maxage`.
#   Seconds from MADEK_PERF_ANON_HTTP_CACHE_S_MAXAGE (600), _STALE_WHILE_REVALIDATE (86400),
#   _STALE_IF_ERROR (86400), read per request.
#   Everything else keeps the Rails default (`private`) or the action's own header; responses that depend on
#   the request (confidential link tokens, SSR fallback pages) get `no-store`, because a shared cache may
#   store a bare `private` on the cookie-less anonymous path.
#   `Vary: Accept` (set by Rails) is kept; there is deliberately no `Vary: Cookie` (it would make the cache
#   useless) and no `Vary: Accept-Language` (the locale only comes from `?lang=`).
#
# Safety nets: a response is only made public if nothing loaded the Rails session during the request
# (`session_will_be_committed?`), and the `Perf::PublicCacheSetCookieGuard` middleware
# (`lib/perf/public_cache_set_cookie_guard.rb`, inserted by `config/initializers/perf_anon_http_cache.rb`)
# downgrades any `public` response that still carries a `Set-Cookie` header.
module Perf
  module AnonHttpCache
    extend ActiveSupport::Concern

    # anonymous pages that make a non-GET request and therefore keep their CSRF token (and stay private):
    # the export page POSTs to the checksum endpoints; test_auth (dev/test) renders the password form
    KEEP_CSRF_TOKEN = { 'media_entries' => %w(export), 'test_auth' => %w(*) }.freeze

    CACHEABLE_STATUSES = [200, 404].freeze
    CACHEABLE_MEDIA_TYPES = %w(text/html application/json).freeze

    # query params that carry a confidential link token (see ControllerHelpers)
    CONFIDENTIAL_PARAMS = %w(access accessToken token).freeze

    # files are authorized per request; embedded views write the Referer into the page
    NEVER_PUBLIC_CONTROLLERS = %w(media_files previews zencoder_jobs sessions test_auth).freeze
    NEVER_PUBLIC_ACTIONS = %w(
      embedded fullscreen show_by_confidential_link image video audio document
    ).freeze
    # same by path, also covers error pages rendered by ErrorsController
    NEVER_PUBLIC_PATHS = %r{
      \A/(media|files)/ |
      /(embedded|fullscreen)(\z|[/.]) |
      /access/ |
      \A/entries/[^/]+/(image|video|audio|document)(\z|[/.])
    }x

    # D×C contract: option D (SSR) sets this env key when server rendering fell back to client rendering
    SSR_FALLBACK_ENV_KEY = 'madek.ssr_fallback'.freeze

    included do
      # must run before ErrorsController#show's `flash.keep` (any before_action does)
      before_action :perf_skip_error_page_session
      # position relative to `verify_authorized` does not matter
      after_action :perf_anon_http_cache_headers
    end

    # NOTE: the two query methods below MUST stay public: the layout, `UiHelper#react` and the 404 page call
    # them via `controller.try(...)`, and `try` only calls public methods (nil otherwise = upstream behaviour).

    # used by the layout (`csrf_meta_tag`) and the `react` helper (`authToken`)
    def omit_authenticity_token?
      return @_perf_omit_token if defined?(@_perf_omit_token)
      keep = KEEP_CSRF_TOKEN.fetch(controller_name, [])
      @_perf_omit_token = %w(GET HEAD).include?(original_request_method) && current_user.nil? &&
        !keep.include?('*') && !keep.include?(action_name.to_s)
    end

    # request-level part of the decision (the response-level part is in the `after_action`);
    # also used by the client error page (no render timestamp in a page that shared caches may store)
    def anonymous_http_cache_candidate?
      omit_authenticity_token? &&
        !confidential_request? &&
        !NEVER_PUBLIC_CONTROLLERS.include?(controller_name) &&
        !NEVER_PUBLIC_ACTIONS.include?(action_name.to_s) &&
        !NEVER_PUBLIC_PATHS.match?(original_request_path)
    end

    private

    # The client PATCHes /session/list_config on layout/order/filter changes; for anonymous users that is a no-op
    # (UserListParams persists only for current_user). Their pages carry no token any more, so let this one
    # request through instead of raising InvalidAuthenticityToken. Signed-in users are still checked.
    # (Overriding the predicate instead of `skip_forgery_protection`: ApplicationController's later
    # `protect_from_forgery` would replace a conditional skip made from here.)
    def verified_request?
      super || (controller_name == 'users' && action_name == 'set_list_config' && current_user.nil?)
    end

    # error pages (exceptions_app) load the failed request's session and would re-send `_madek_session` on every
    # anonymous 401/404; nothing to persist without a token and without an existing session cookie
    def perf_skip_error_page_session
      return unless request.get_header('action_dispatch.exception') && omit_authenticity_token?
      return if request.cookies[Madek::Constants::Webapp::SESSION_NAME].present?
      request.session_options[:skip] = true
    end

    def perf_anon_http_cache_headers
      # D×C: a page where SSR fell back to client rendering must never be stored (any visitor)
      if request.env[SSR_FALLBACK_ENV_KEY]
        response.headers['X-Madek-SSR-Fallback'] = '1'
        response.cache_control.replace(private: true, no_store: true)
        return
      end
      error_page = request.get_header('action_dispatch.exception').present?
      # keep explicit decisions of the action (`disable_http_caching`, `stale?`, error pages) except for the
      # error 404 (its raw `no-store` is overridden by `expires_in` below if the 404 is cacheable)
      if response.headers['Cache-Control'].present? || response.cache_control.any?
        return unless error_page && response.status == 404
      end
      return no_store if confidential_request?
      return unless anonymous_http_cacheable_response?
      expires_in(
        0,
        public: true,
        stale_while_revalidate: MadekPerf.value(:anon_http_cache_stale_while_revalidate, 86_400).to_i,
        stale_if_error: MadekPerf.value(:anon_http_cache_stale_if_error, 86_400).to_i,
        's-maxage': MadekPerf.value(:anon_http_cache_s_maxage, 600).to_i)
    end

    def confidential_request?
      action_name.to_s == 'show_by_confidential_link' ||
        original_request_path.include?('/access/') ||
        CONFIDENTIAL_PARAMS.any? { |k| request.query_parameters.key?(k) }
    end

    def anonymous_http_cacheable_response?
      anonymous_http_cache_candidate? &&
        CACHEABLE_STATUSES.include?(response.status) &&
        CACHEABLE_MEDIA_TYPES.include?(response.media_type) &&
        !session_will_be_committed?
    end

    # something read or wrote the Rails session (e.g. a request with an old session cookie rendering the
    # flash) -> it will be re-sent as Set-Cookie and the body may depend on it -> not public
    def session_will_be_committed?
      session = request.session
      session.respond_to?(:loaded?) && session.loaded? && !request.session_options[:skip]
    end

    # ErrorsController runs via `exceptions_app`: ShowExceptions rewrites the method to GET and the path to
    # `/<status>`, the originals are kept in env
    def original_request_method
      request.get_header('action_dispatch.original_request_method') || request.request_method
    end

    def original_request_path
      request.get_header('action_dispatch.original_path') || request.path
    end
  end
end
