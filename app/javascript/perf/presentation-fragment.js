// Presentation parameters in the URL fragment (perf option P).
//
// `list[layout]`, `list[show_filter]` and `list[accordion]` only change how a resource list is
// shown, not what it contains. With MADEK_PERF_DONT_CACHE_PRESENTATION_PARAMS (Rails concern
// `Perf::PresentationParams`) or the equivalent Varnish switch, an anonymous HTML request that
// carries them is redirected to the same URL without them; the values travel in the fragment
// (read here) and in a preference cookie for clients without JavaScript. This file ships without
// a toggle: without a fragment and without the cookie it does nothing (upstream behaviour).
//
// FORMAT CONTRACT (Rails and Varnish must produce exactly this):
//
// 1. Matching. The query is split on `&` (empty segments dropped). In every segment `[` -> `%5B`,
//    `]` -> `%5D`, `%5b` -> `%5B`, `%5d` -> `%5D`. A segment is a presentation segment iff it
//    matches `^list%5B(layout|show_filter|accordion)%5D=(.*)$`; the value is kept raw (as sent,
//    not decoded). If a key occurs more than once, the last occurrence wins.
// 2. Redirect. `302 Found`, `Cache-Control: no-store`, relative
//    `Location: <path>[?<kept>]#<fragment>` where <path> is the request path as sent, <kept> the
//    other (canonicalised) segments in their original order joined with `&` (no `?` if none),
//    and <fragment> = `list%5B<key>%5D=<raw value>` joined with `&` in the fixed key order
//    layout, show_filter, accordion. Example:
//      GET /sets/X?list[layout]=list&list[page]=2&list[show_filter]=true
//      -> Location: /sets/X?list%5Bpage%5D=2#list%5Blayout%5D=list&list%5Bshow_filter%5D=true
// 3. Cookie (set by the redirect only, value replaced, never merged):
//      Set-Cookie: madek_list=<C>; Path=/; Max-Age=<s>; SameSite=Lax[; Secure]   (not HttpOnly)
//    Secure iff the request is https; Max-Age default 2592000 (30 days). C is the
//    form-component encoding (Ruby `Rack::Utils.escape`: only `A-Za-z0-9*._-` stay literal,
//    everything else `%XX`) of the inner string `list[<key>]=<raw value>` joined with `&` in the
//    same key order, containing only the segments that pass:
//      layout: raw value is one of grid|tiles|list|miniature
//      show_filter: raw value is true|false
//      accordion: raw value is non-empty and matches ^[A-Za-z0-9._%*-]+$ (JSON is checked on read)
//    If C would exceed 1024 bytes the accordion segment is left out. No passing segment -> no
//    Set-Cookie (the redirect still happens). Example (from the request above):
//      madek_list=list%5Blayout%5D%3Dlist%26list%5Bshow_filter%5D%3Dtrue
//    For enum values and raw values from the allowed alphabet this equals: take <fragment>,
//    replace `%` -> `%25`, then `list%255B<key>%255D=` -> `list%5B<key>%5D%3D`, then `&` -> `%26`.
// 4. Reading the cookie (no-JS visitors): percent-decode C once, split on `&`; every segment must
//    match `^list\[(layout|show_filter|accordion)\]=([^&]*)$` and the total ≤ 1024 bytes, otherwise
//    the whole cookie is ignored. Values are percent-decoded; a value that fails the rules above
//    (accordion: not a JSON object) is dropped. The rest is merged into the list params of the
//    request, which is then rendered uncached (`Cache-Control: private`).
// 5. This reader (JS visitors): `qs.parse` of the fragment, restricted to the three keys (empty
//    values dropped), merged over the query parse; it deletes the `madek_list` cookie whenever it
//    is present, so JS visitors never use the uncached cookie path.
import { get, isEmpty, merge, pick, pickBy } from 'lodash-es'
import qs from 'qs'

const KEYS = ['layout', 'show_filter', 'accordion']
const COOKIE = 'madek_list'

export function parsePresentationFragment(location) {
  const hash = (location && location.hash) || ''
  const list = hash.length > 1 ? get(qs.parse(hash.slice(1)), 'list') : undefined
  if (!list || typeof list !== 'object') return {}
  return pickBy(pick(list, KEYS), v => typeof v === 'string' && v !== '')
}

export function deletePresentationCookie(location) {
  if (typeof document === 'undefined') return
  if (!new RegExp(`(^|;\\s*)${COOKIE}=`).test(document.cookie)) return
  const secure = location && location.protocol === 'https:' ? '; Secure' : ''
  document.cookie = `${COOKIE}=; Max-Age=0; Path=/; SameSite=Lax${secure}`
}

// used by shared/resource_list_params.js: query parse + fragment (unchanged without a fragment)
export function withPresentationFragment(query, location) {
  deletePresentationCookie(location)
  const fragment = parsePresentationFragment(location)
  return isEmpty(fragment) ? query : merge(query, { list: fragment })
}

// used by MediaResourcesBox#componentDidMount: the server rendered the default layout, so a
// `list` layout from the fragment has no list metadata yet; load it as a layout click does
export function presentationFragmentMounted(box, location) {
  if (parsePresentationFragment(location).layout === 'list') {
    box.setState({}, box.fetchListMetadata)
  }
}
