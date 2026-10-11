# MADEK_PERF_LIST_COUNTS (unset/sync = upstream): list totals for anonymous
# visitors on the main resource lists.
#
# Every list request runs a COUNT over the whole filtered scope
# (`MediaResources#_total_count`), also for every crawler request and every
# autoscroll page. With this toggle, lists that opt in (`count_deferrable: true`
# at the construction site; main lists only, never relation lists or
# dashboards) skip that COUNT for anonymous visitors:
#
#   sync  - COUNT in the page request (default, upstream behaviour)
#   async - the page is rendered without the total; with JavaScript the box
#           requests the same URL with `list[count]=true` and shows the total
#           in its title when it arrives (app/javascript/perf/listCounts.js).
#           Visitors without JavaScript never trigger the COUNT.
#   none  - no total at all
#
# Without the total, `any?`/`empty?` use an EXISTS query, `pagination` carries
# `total_pages: nil` and `count_mode`, and the client paginates by
# `pagination.prev/next` (no-JS fallback) or until a short page (autoscroll).
# Any other value counts as `sync`. Logged-in users always get `sync`.
module Perf
  class ListCounts
    DEFERRED_MODES = %w(async none).freeze

    # 'sync' | 'async' | 'none'
    def self.mode(user, deferrable)
      return 'sync' unless user.nil? && deferrable
      setting = MadekPerf.value(:list_counts, 'sync').to_s.strip.downcase
      DEFERRED_MODES.include?(setting) ? setting : 'sync'
    end

    attr_reader :mode

    # `with_count`: the caller wants a total at all (upstream kwarg; when false
    # nothing here changes the upstream output)
    def initialize(user, deferrable:, with_count:, conf:)
      @with_count = with_count
      @mode = with_count ? self.class.mode(user, deferrable) : 'sync'
      @conf = conf || {}
    end

    # is the COUNT run in this request?
    def count_in_request?
      return false unless @with_count
      case @mode
      when 'none' then false
      when 'async' then @conf[:count] == true
      else true
      end
    end

    # the caller wants a total, but the mode skips it in this request
    def deferred?
      @with_count && !count_in_request?
    end

    # memoized EXISTS on the *unpaginated* but filtered scope (replaces
    # `COUNT > 0` for `any?`/`empty?`, which are both part of the dump)
    def exists?(scope)
      return @exists if defined?(@exists)
      @exists = scope.exists?
    end

    # upstream pagination hash, unchanged in `sync`
    def pagination(pagination)
      return pagination if @mode == 'sync'
      pagination[:total_pages] = nil if deferred?
      pagination.merge(count_mode: @mode)
    end
  end
end
