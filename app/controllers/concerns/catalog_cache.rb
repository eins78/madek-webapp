module CatalogCache
  extend ActiveSupport::Concern

  CACHE_KEY = 'explore_catalog_section'.freeze

  def catalog_cache
    if AppSetting.first.try(:catalog_caching)
      Rails.cache.fetch("#{CACHE_KEY}/#{I18n.locale}", # the dump has localized labels
                        expires_in: CacheHelper.catalog_cache_duration) do
        yield
      end
    else
      # MADEK_PERF_ANON_CACHES (default off = upstream): caches the catalog section, keyword statistics, the root/explore list
      # markup and the filter-sidebar aggregates for anonymous visitors for a few minutes per process (_TTL, default 300 s).
      # Measured: -22 % CPU per request, -46 % p95 (with the other query fixes) in a crawler-weighted benchmark on production-shaped data
      # (maintainers' perf notes, 2026-10). Implementation: app/lib/perf/anon_caches.rb.
      Perf::AnonCaches.fetch(:catalog, CACHE_KEY, user: current_user) { yield }
    end
  end
end
