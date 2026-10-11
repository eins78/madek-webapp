# MADEK_PERF_ANON_CACHES (default off = upstream behaviour): short-lived caches
# for anonymous visitors of data that is the same for every anonymous visitor
# and expensive to compute: the catalog section, the keyword statistics, the
# root/explore list markup and the filter-sidebar aggregates.
#
# - Only for anonymous visitors (`user: nil`); logged-in users always get fresh
#   data.
# - Entries live in `Rails.cache` (per Puma worker with the default
#   `:memory_store`, sized by WEBAPP_CACHE_SIZE_MB) and expire after
#   MADEK_PERF_ANON_CACHES_TTL seconds (default 300; 0 disables the caches
#   even when the toggle is on). A new public entry can therefore show up in
#   these places up to the TTL later, per worker.
# - Keys include the locale (the cached data contains localized labels).
# - Only plain values (hashes, arrays, strings, AR records) are cached, never
#   presenters.
#
# With the toggle off every method returns what the block returns, untouched.
module Perf
  module AnonCaches
    DEFAULT_TTL = 300 # seconds

    def self.enabled?
      MadekPerf.on?(:anon_caches) && ttl > 0
    end

    def self.ttl
      MadekPerf.value(:anon_caches_ttl, DEFAULT_TTL).to_i
    end

    # Caches the block's value for anonymous visitors. `key_parts` identify the
    # value (relations are keyed by their SQL); they are only evaluated into a
    # key when caching is active.
    def self.fetch(name, *key_parts, user:)
      return yield unless user.nil? && enabled?
      Rails.cache.fetch(key(name, key_parts),
                        expires_in: ttl.seconds,
                        race_condition_ttl: 10.seconds) { yield }
    end

    # Key for server-rendered list markup (`react_cached_for_anonymous`), or
    # nil when caching is not active. Keyed by name, path and locale (not by the
    # props), so the props and their queries are only built on a miss.
    def self.markup_key(cache_name, path)
      return unless enabled?
      ['perf-anon', 'react', cache_name, path, I18n.locale].join('/')
    end

    def self.key(name, key_parts)
      parts = key_parts.map { |part| part.respond_to?(:to_sql) ? part.to_sql : part }
      ['perf-anon', name, Digest::SHA256.hexdigest(parts.to_json), I18n.locale]
        .join('/')
    end
    private_class_method :key
  end
end
