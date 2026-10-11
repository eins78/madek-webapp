require 'spec_helper'
require Rails.root.join 'spec', 'presenters', 'shared', 'dump'

describe Presenters::MetaData::MetaDataListDetails do
  before :each do
    PresenterRequestMemo.reset
    app_setting = AppSetting.first || create(:app_setting)

    @media_entry = create(:media_entry, is_published: true)
    @owner = @media_entry.responsible_user

    public_key = MetaKey.find_by(id: 'test:string') || create(:meta_key_text)
    hidden_vocabulary = create(:vocabulary,
                               id: 'listdetailshidden',
                               enabled_for_public_view: false)
    hidden_key = create(:meta_key_text,
                        id: 'listdetailshidden:secret',
                        vocabulary: hidden_vocabulary)
    key_without_data = create(:meta_key_text, id: 'test:listdetailsempty')
    create(:vocabulary_user_permission,
           vocabulary: hidden_vocabulary, user: @owner, view: true, use: false)

    @context = create(:context)
    [public_key, hidden_key, key_without_data].each do |meta_key|
      create(:context_key, context: @context, meta_key: meta_key)
    end
    app_setting.update!(contexts_for_list_details: [@context.id])

    create(:meta_datum_text, media_entry: @media_entry, meta_key: public_key)
    create(:meta_datum_text, media_entry: @media_entry, meta_key: hidden_key)
  end

  def list_details_dump(klass, user, preload: false)
    resource = MediaEntry.find(@media_entry.id)
    ::MediaResources::MetaData.preload_for_list!([resource]) if preload
    Presenter.dump_recur(klass.new(resource, user).contexts_for_list_details)
  end

  [[:anonymous, 1], [:owner, 2]].each do |who, visible_count|
    context "for #{who}" do
      let(:user) { who == :owner ? @owner : nil }

      it 'dumps the same `contexts_for_list_details` as MetaDataShow' do
        expected = list_details_dump(Presenters::MetaData::MetaDataShow, user)
        expect(expected.size).to eq 1
        expect(expected.first[:meta_data].size).to eq visible_count

        PresenterRequestMemo.reset
        expect(list_details_dump(described_class, user)).to eq expected
        expect(list_details_dump(described_class, user, preload: true)).to eq expected
      end
    end
  end

  it 'does not share the per-request memo between users' do
    anonymous = list_details_dump(described_class, nil)
    owner = list_details_dump(described_class, @owner)
    expect(anonymous.first[:meta_data].size).to eq 1
    expect(owner.first[:meta_data].size).to eq 2
  end

  it 'is what MediaResourceListMetadata dumps as `meta_data`' do
    dump = Presenters::MediaResources::MediaResourceListMetadata
      .new(@media_entry, nil).dump
    expect(dump[:meta_data][:contexts_for_list_details])
      .to eq list_details_dump(described_class, nil)
    expect(dump[:meta_data]).not_to have_key :by_vocabulary
  end

  it_can_be 'dumped' do
    let(:presenter) do
      media_entry = create(:media_entry)
      described_class.new(media_entry, media_entry.responsible_user)
    end
  end
end
