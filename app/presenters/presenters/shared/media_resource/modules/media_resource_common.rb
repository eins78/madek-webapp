module Presenters
  module Shared
    module MediaResource
      module Modules
        module MediaResourceCommon
          extend ActiveSupport::Concern
          include Presenters::Shared::MediaResource::Modules::Responsible

          included do
            delegate_to_app_resource :title
          end

          def created_at_pretty
            @app_resource.created_at
              .in_time_zone(AppSetting.first.time_zone)
              .strftime('%d.%m.%Y')
          end

          def portrayed_object_date_pretty
            meta_datum_string('madek_core:portrayed_object_date')
          end

          def copyright_notice_pretty
            meta_datum_string('madek_core:copyright_notice')
          end

          def authors_pretty
            @app_resource.authors || ''
          end

          def destroyable
            false
          end

          def editable
            false
          end

          def collection_manageable
            false
          end

          def clipboard_url
            my_dashboard_section_path(:clipboard)
          end

          def used_confidential_access_token
            return unless @app_resource
                           .respond_to?(:accessed_by_confidential_link)

            token = @app_resource.accessed_by_confidential_link
            return token if token.is_a?(String) && token.present?
          end

          private

          # PERF: lists preload all `meta_data` of their items
          # (`MediaResources::MetaData.preload_for_list!`), but `find_by` on
          # the association always hits SQL (2 queries per list item). Use the
          # loaded records when they are there.
          def meta_datum_string(meta_key_id)
            meta_data = @app_resource.meta_data
            md = if meta_data.loaded?
              meta_data.detect { |m| m.meta_key_id == meta_key_id }
            else
              meta_data.find_by(meta_key_id: meta_key_id)
            end
            md ? md.string : ''
          end
        end
      end
    end
  end
end
