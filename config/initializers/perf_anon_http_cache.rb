# MADEK_PERF_ANON_HTTP_CACHE (see app/controllers/concerns/perf/anon_http_cache.rb): last line of defence,
# a response marked public for shared caches must never carry Set-Cookie. ENV is read directly because
# app/lib (MadekPerf) is not autoloadable while initializers run; same truthiness rule as MadekPerf.on?.
if %w(1 true yes on).include?(ENV['MADEK_PERF_ANON_HTTP_CACHE'].to_s.strip.downcase)
  require Rails.root.join('lib', 'perf', 'public_cache_set_cookie_guard').to_s
  Rails.application.config.middleware.insert_before ActionDispatch::ShowExceptions, Perf::PublicCacheSetCookieGuard
end
