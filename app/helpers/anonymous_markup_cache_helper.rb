# Server-rendered component markup cached in `Rails.cache` for sections that
# are the same for every anonymous visitor (the lists on `/` and `/explore`).
#
# The markup can only be shared if it contains nothing visitor-specific:
# - it is only cached for anonymous visitors; logged-in users render directly
#   (their dumps contain user state);
# - it is rendered without the CSRF token (`authToken: nil`; only the favorite
#   button uses it, which anonymous visitors never get; the page's
#   `csrf-token` meta tag is untouched) and with `for_url` = the path;
# - only prerendered markup is stored (a `?___norender=1` request must not
#   store the unrendered placeholder for later visitors), and nothing is
#   stored when server rendering fell back to client rendering
#   (`request.env['madek.ssr_fallback']`);
# - the key covers name, locale, path and a stable digest of the props
#   (content-addressed, so it never serves stale content; `Hash#hash` is
#   seeded per Ruby process and could not be shared between processes).
module AnonymousMarkupCacheHelper
  SSR_FALLBACK_ENV_KEY = 'madek.ssr_fallback'.freeze

  def react_prerender?
    !params.permit(:___norender).present?
  end

  # props are given as a block: `react_cached_for_anonymous(name, component) { props }`
  def react_cached_for_anonymous(cache_name, name, &props)
    return react(name, props.call) unless current_user.nil? && react_prerender?
    props_hash = props.call
    key = [
      'react-anon', cache_name, I18n.locale, request.path,
      Digest::SHA256.hexdigest(props_hash.to_json)
    ].join('/')
    cached_anonymous_markup(key, name) { props_hash }
  end

  # read -> render -> write (instead of `Rails.cache.fetch`, which can not
  # skip the write when the render fell back to client rendering)
  def cached_anonymous_markup(key, name, expires_in: nil)
    if (html = Rails.cache.read(key))
      return html.html_safe
    end
    html = react(name, yield, auth_token: false, for_url: request.path).to_str
    unless request.env[SSR_FALLBACK_ENV_KEY]
      Rails.cache.write(key, html, expires_in: expires_in)
    end
    html.html_safe
  end
end
