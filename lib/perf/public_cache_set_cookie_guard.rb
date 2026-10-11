# MADEK_PERF_ANON_HTTP_CACHE, last line of defence for Perf::AnonHttpCache (inserted only when the toggle is on,
# see config/initializers/perf_anon_http_cache.rb): a response that a shared cache may store (`public` /
# `s-maxage`) must never carry a `Set-Cookie` header, otherwise one visitor's cookie (Rails session, CSRF
# secret) could be served to everybody (Varnish stores Set-Cookie unless told otherwise; Apache only strips it
# because of `CacheIgnoreHeaders Set-Cookie`).
#
# Sits outside of ShowExceptions, i.e. sees the final headers of normal responses and of error pages, after the
# session/cookie middlewares ran.
#
# NOTE: nested `module Perf` (not `Perf::…`): the initializer requires this file before the autoloader is set up.
module Perf
  class PublicCacheSetCookieGuard
    SHARED_CACHEABLE = /(\A|[\s,])(public|s-maxage=)/i

    def initialize(app)
      @app = app
    end

    def call(env)
      status, headers, body = @app.call(env)
      cc_key = header_key(headers, 'cache-control')
      sc_key = header_key(headers, 'set-cookie')
      if cc_key && sc_key && headers[sc_key].present? && SHARED_CACHEABLE.match?(headers[cc_key].to_s)
        Rails.logger.warn(
          "PublicCacheSetCookieGuard: public response with Set-Cookie, made private: #{env['PATH_INFO']}")
        headers[cc_key] = 'max-age=0, private, must-revalidate'
      end
      [status, headers, body]
    end

    private

    def header_key(headers, name)
      headers.keys.find { |k| k.to_s.casecmp?(name) }
    end
  end
end
