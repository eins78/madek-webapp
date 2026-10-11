// MADEK_PERF_SIGN_IN_RETURN_TO: the sign-in link is rendered with the current path only (or without
// `return-to`), so that crawlers see one sign-in URL per page instead of one per page variant.
// Add the full current URL right before the link is followed. Inert without `a[data-sign-in-return-to]`.
const parseUrl = require('url').parse
const buildUrl = require('url').format
const { each } = require('lodash-es')

const addSignInReturnTo = event => {
  const link =
    event.target && event.target.closest && event.target.closest('a[data-sign-in-return-to]')
  if (!link) return
  const parsedUrl = parseUrl(link.href, true)
  parsedUrl.query['return-to'] = location.pathname + location.search
  delete parsedUrl.search
  link.href = buildUrl(parsedUrl)
}

each(['click', 'auxclick', 'contextmenu'], type =>
  document.addEventListener(type, addSignInReturnTo, true)
)
