// MADEK_PERF_LIST_COUNTS, client side (server: app/lib/perf/list_counts.rb).
//
// With `async` or `none` the server leaves the list total out of the page for
// anonymous visitors: `pagination.total_count` and `.total_pages` are null and
// `pagination.count_mode` is set. Everything here is driven by that data: when
// the dump carries a total (upstream, `sync`) nothing changes.

import { get as _get, set as _set } from 'lodash-es'
import xhr from 'xhr'
import setUrlParams from '../lib/set-params-for-url.js'

// shown in the box title (client only) while the deferred total is loading;
// never rendered on the server, so visitors without JS see no placeholder
const PENDING_TOTAL = '…'

// BoxPaginationNav with an unknown total. Returns `undefined` when the total
// is known (the upstream code path applies), otherwise what to render:
// - server/no JS: 'fallback' (prev/next links from `pagination.prev/next`,
//   which never needed the total)
// - client: 'autoscroll' while there is a next page and the last loaded page
//   was not short (`reachedEnd`, see mediaResourcesBoxState/state.js)
// - null: nothing
function unknownTotalNav({ staticPagination, isClient, reachedEnd }) {
  if (!staticPagination || !staticPagination.count_mode) return undefined
  if (staticPagination.total_pages != null) return undefined
  if (isClient) return staticPagination.next && !reachedEnd ? 'autoscroll' : null
  return staticPagination.next || staticPagination.prev ? 'fallback' : null
}

// box title: the static total, else the deferred one from the box's component
// state (a number, PENDING_TOTAL while loading, or undefined)
function titleTotalCount(staticTotalCount, componentState) {
  return staticTotalCount != null ? staticTotalCount : componentState.deferredTotalCount
}

// `async`: after mount, request the same URL with `list[count]=true`, dumping
// only the list's `pagination`, and put the total into the box state.
function fetchDeferredTotalCount(box) {
  const pagination = _get(box.props, 'get.pagination') || {}
  if (pagination.count_mode !== 'async' || pagination.total_count != null) return
  const jsonPath = box.getJsonPath() || ''
  if (!/(^|\.)resources$/.test(jsonPath)) return
  const paginationPath = jsonPath.replace(/resources$/, 'pagination')

  const url = setUrlParams(
    box._currentUrl(),
    { list: { count: true } },
    { ___sparse: JSON.stringify(_set({}, paginationPath, {})) }
  )
  box.setState({ deferredTotalCount: PENDING_TOTAL })
  xhr.get({ url, json: true }, (err, res, body) => {
    const total =
      !err && res && res.statusCode === 200 ? _get(body, `${paginationPath}.total_count`) : null
    box.setState({ deferredTotalCount: typeof total === 'number' ? total : undefined })
  })
}

export { unknownTotalNav, titleTotalCount, fetchDeferredTotalCount }
