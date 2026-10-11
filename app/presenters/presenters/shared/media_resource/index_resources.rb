module Presenters
  module Shared
    module MediaResource
      class IndexResources < Presenter
        include Presenters::Shared::MediaResource::Modules::IndexPresenterByClass

        def initialize(user, resources, async_cover: false)
          @user = user
          @given_resources = resources
          @async_cover = async_cover
        end

        def resources
          @resources ||= build_resources
        end

        private

        def build_resources
          records = @given_resources.to_a
          # PERF: same preload as the paginated lists; without it every item
          # queried its title, subtitle, keywords and authors one by one.
          # Used by the root/explore lists and by set highlights.
          ::MediaResources::MetaData.preload_for_list!(
            records.select { |r| r.is_a?(::MediaEntry) || r.is_a?(::Collection) })
          records.map do |resource|
            presenter = presenter_by_resource_type(resource) || presenter_by_class(resource.class)
            if resource.class == Collection
              presenter.new(resource, @user, async_cover: @async_cover)
            else
              presenter.new(resource, @user)
            end
          end
        end

      end
    end
  end
end
