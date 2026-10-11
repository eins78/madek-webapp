module Presenters
  module MediaResources
    class MediaResourceListMetadata < Presenters::Shared::AppResource

      def initialize(app_resource, user)
        super(app_resource)
        @user = user
      end

      # only what the `list` layout renders (see `MetaDataListDetails`)
      def meta_data
        Presenters::MetaData::MetaDataListDetails.new(@app_resource, @user)
      end

      def relation_counts
        Presenters::MediaResources::RelationCounts.new(@app_resource, @user)
      end
    end
  end
end
