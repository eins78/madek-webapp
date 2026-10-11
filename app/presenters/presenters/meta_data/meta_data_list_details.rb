module Presenters
  module MetaData
    # Meta data for the `list` layout of resource lists (`list_meta_data`).
    #
    # PERF: this used to be a full `MetaDataShow` per list item, which dumps
    # *every* public method: `by_vocabulary` (all meta data), the entry and
    # collection summary contexts, the "extra" contexts and the list details,
    # each with one meta key, vocabulary and meta datum lookup per context key.
    # The client (`ListThumbnail.jsx`) only reads `contexts_for_list_details`.
    # Same structure and visibility rules as
    # `MetaDataShow#contexts_for_list_details`.
    #
    # The lookups that are the same for every item (contexts, their keys,
    # meta keys, vocabulary visibility for the user) are memoized per request;
    # the item's meta data come from the list preload when it is loaded.
    class MetaDataListDetails < Presenters::Shared::AppResource
      include Presenters::Shared::Modules::VocabularyConfig

      def initialize(app_resource, user)
        super(app_resource)
        @user = user
      end

      def contexts_for_list_details
        @contexts_for_list_details ||= list_contexts.map do |context, c_keys|
          Pojo.new(
            context: Presenters::Contexts::ContextCommon.new(context),
            meta_data: c_keys.map { |ck| key_value_pair(ck) }.compact)
        end
      end

      private

      # [[Context, [ContextKey (with meta_key + vocabulary)]], ...]
      def list_contexts
        PresenterRequestMemo.fetch(:list_details_contexts, @user.try(:id)) do
          _contexts_for_list_details.map do |context|
            c_keys = context.context_keys
              .includes(meta_key: :vocabulary).to_a
              .select { |ck| vocabulary_visible?(ck.meta_key.vocabulary) }
            [context, c_keys]
          end
        end
      end

      def vocabulary_visible?(vocabulary)
        PresenterRequestMemo.fetch(:vocabulary_viewable, vocabulary.id, @user.try(:id)) do
          vocabulary.viewable_by_user?(@user)
        end
      end

      def key_value_pair(context_key)
        md = meta_datum_for(context_key.meta_key_id)
        return unless md
        Pojo.new(
          context_key: Presenters::ContextKeys::ContextKeyCommon.new(context_key),
          meta_datum: Presenters::MetaData::MetaDatumCommon.new(md, @user))
      end

      def meta_datum_for(meta_key_id)
        meta_data = @app_resource.meta_data
        if meta_data.loaded?
          meta_data.detect { |md| md.meta_key_id == meta_key_id }
        else
          meta_data.find_by(meta_key_id: meta_key_id)
        end
      end
    end
  end
end
