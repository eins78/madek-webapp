module Presenters
  module Explore
    module Modules
      class ExploreKeywordsSection < Presenter

        def initialize(limit: 24, user: nil)
          @limit = limit
          @user = user
        end

        def empty?
          keywords.blank?
        end

        def content
          # memoized: the partials read `content` several times
          return @content if defined?(@content)
          @content = _content
        end

        def _content
          return if empty?
          {
            type: 'keyword',
            id: 'keywords',
            data: keywords_overview,
            show_all_link: true,
            show_all_text: I18n.t(:explore_show_more),
            show_title: true
          }
        end

        private :_content

        private

        def keywords_overview
          {
            title: I18n.t(:explore_keywords_section_title),
            url: explore_keywords_path,

            # MADEK_PERF_ANON_CACHES (default off = upstream): keyword usage counts cached for anonymous visitors (TTL, per process).
            # Measured: -22 % CPU per request, -46 % p95 (with the other query fixes) in a crawler-weighted benchmark on production-shaped data
            # (maintainers' perf notes, 2026-10). Implementation: app/lib/perf/anon_caches.rb.
            list: Perf::AnonCaches.fetch(:keyword_stats, @limit, user: @user) { keywords.with_usage_count.to_a }.map do |keyword|
              {
                url: prepend_url_context(
                  explore_catalog_category_path('madek_core:keywords')
                ),
                keyword: \
                  Presenters::Keywords::KeywordIndexWithUsageCount.new(keyword)
              }
            end
          }
        end

        def keywords
          @keywords ||= \
            MetaKey
            .find_by(id: 'madek_core:keywords')
            .try(:keywords)
            .try(:limit, @limit)
        end
      end
    end
  end
end
