# MADEK_PERF_DONT_CACHE_PRESENTATION_PARAMS (default off = upstream behaviour).
#
# `list[layout]`, `list[show_filter]` and `list[accordion]` only change how a
# resource list is shown. Anonymous GET/HEAD HTML requests that carry one of
# them get a 302 to the same URL without them; the values move into the URL
# fragment (restored by app/javascript/perf/presentation-fragment.js) and into
# a preference cookie `madek_list` for clients without JavaScript. So only the
# default presentation of a list is rendered and may be cached.
# A later request without presentation params but with a valid cookie is
# rendered with the cookie's presentation and marked `private`.
#
# Never touched: JSON requests, `___sparse` requests, requests carrying the
# `madek-session` cookie or an `Authorization` header, and requests carrying
# `X-Madek-List-Cookie` (the Varnish variant of this option has already
# applied the cookie; redirecting again would loop).
#
# The exact redirect/fragment/cookie format is documented at the top of
# app/javascript/perf/presentation-fragment.js (shared with the Varnish
# variant). Knob: MADEK_PERF_DONT_CACHE_PRESENTATION_PARAMS_COOKIE_MAX_AGE
# (seconds, default 30 days).
module Perf
  module PresentationParams
    extend ActiveSupport::Concern

    KEYS = %w(layout show_filter accordion).freeze
    COOKIE_NAME = 'madek_list'.freeze
    COOKIE_MAX_BYTES = 1024
    COOKIE_MAX_AGE_DEFAULT = 30 * 24 * 60 * 60
    LAYOUTS = %w(grid tiles list miniature).freeze
    BOOLEANS = %w(true false).freeze
    COOKIE_RAW_VALUE = /\A[A-Za-z0-9._%*-]+\z/
    QUERY_SEGMENT = /\Alist%5B(layout|show_filter|accordion)%5D=(.*)\z/m
    COOKIE_SEGMENT = /\Alist\[(layout|show_filter|accordion)\]=([^&]*)\z/
    VARNISH_HEADER = 'X-Madek-List-Cookie'.freeze

    included do
      prepend_around_action :perf_presentation_params
    end

    private

    def perf_presentation_params
      return yield unless perf_presentation_candidate?

      kept, found = perf_presentation_split_query
      return perf_presentation_redirect(kept, found) unless found.empty?

      list = perf_presentation_cookie_list
      return yield unless list && perf_presentation_inject(list)

      yield
      # the body depends on the cookie: never shared-cacheable (overrides a
      # `public` set by an after_action, keeps e.g. `no-store`)
      response.cache_control.merge!(public: false, private: true)
    end

    def perf_presentation_candidate?
      # runtime check as well, so the concern is inert if included with the toggle off
      MadekPerf.on?(:dont_cache_presentation_params) &&
        (request.get? || request.head?) &&
        request.format.html? &&
        !request.query_parameters.key?('___sparse') &&
        request.headers['Authorization'].blank? &&
        request.headers[VARNISH_HEADER].blank? &&
        cookies[Madek::Constants::MADEK_SESSION_COOKIE_NAME].blank?
    rescue ActionDispatch::Http::MimeNegotiation::InvalidType
      false
    end

    # => [kept segments (canonical brackets, original order), { key => raw value }]
    def perf_presentation_split_query
      kept = []
      found = {}
      request.query_string.to_s.split('&').each do |segment|
        next if segment.empty?
        segment = segment.gsub('[', '%5B').gsub(']', '%5D')
                         .gsub('%5b', '%5B').gsub('%5d', '%5D')
        if (match = QUERY_SEGMENT.match(segment))
          found[match[1]] = match[2] # last occurrence wins
        else
          kept << segment
        end
      end
      [kept, found]
    end

    def perf_presentation_redirect(kept, found)
      keys = KEYS.select { |key| found.key?(key) }
      fragment = keys.map { |key| "list%5B#{key}%5D=#{found[key]}" }.join('&')
      location = request.path
      location += "?#{kept.join('&')}" unless kept.empty?
      location += "##{fragment}"

      if (value = perf_presentation_cookie_value(found))
        cookies[COOKIE_NAME] = {
          value: value, path: '/', max_age: perf_presentation_cookie_max_age,
          same_site: :lax, secure: request.ssl?, httponly: false }
      end
      response.delete_header('Cache-Control')
      response.cache_control.replace(no_store: true)
      head :found, location: location
    end

    # inner cookie string (the cookie jar form-encodes it), see the format contract
    def perf_presentation_cookie_value(found)
      segments = KEYS
        .select { |key| found.key?(key) && perf_presentation_writable?(key, found[key]) }
        .map { |key| "list[#{key}]=#{found[key]}" }
      value = segments.join('&')
      if Rack::Utils.escape(value).bytesize > COOKIE_MAX_BYTES
        value = segments.reject { |s| s.start_with?('list[accordion]=') }.join('&')
      end
      value.presence
    end

    def perf_presentation_writable?(key, raw)
      case key
      when 'layout' then LAYOUTS.include?(raw)
      when 'show_filter' then BOOLEANS.include?(raw)
      else COOKIE_RAW_VALUE.match?(raw)
      end
    end

    def perf_presentation_cookie_max_age
      age = MadekPerf.value(:dont_cache_presentation_params_cookie_max_age, nil).to_i
      age > 0 ? age : COOKIE_MAX_AGE_DEFAULT
    end

    # => { 'layout' => 'list', ... } or nil; a foreign or malformed segment
    #    invalidates the whole cookie, an invalid value only its segment
    def perf_presentation_cookie_list
      inner = cookies[COOKIE_NAME] # already percent-decoded once by Rack
      return if inner.blank? || inner.bytesize > COOKIE_MAX_BYTES
      list = {}
      inner.split('&').each do |segment|
        match = COOKIE_SEGMENT.match(segment) or return
        value = Rack::Utils.unescape(match[2])
        list[match[1]] = value if perf_presentation_valid?(match[1], value)
      end
      list.presence
    rescue ArgumentError # invalid %-encoding
      nil
    end

    def perf_presentation_valid?(key, value)
      case key
      when 'layout' then LAYOUTS.include?(value)
      when 'show_filter' then BOOLEANS.include?(value)
      else
        begin
          JSON.parse(value).is_a?(Hash)
        rescue JSON::ParserError
          false
        end
      end
    end

    # as if the values had been in the query: `ResourceListParams` reads
    # `params[:list]`, links are built from `request.query_parameters`
    def perf_presentation_inject(list)
      query = request.query_parameters
      current = query['list']
      return false unless current.nil? || current.is_a?(Hash)
      merged = (current || {}).to_h.merge(list)
      query['list'] = merged
      request.parameters['list'] = merged
      params[:list] = merged
      true
    end
  end
end
