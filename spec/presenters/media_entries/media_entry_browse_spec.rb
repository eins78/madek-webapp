require 'spec_helper'

describe Presenters::MediaEntries::Modules::MediaEntryBrowse do
  before :each do
    AppSetting.first || create(:app_setting)
    meta_key = MetaKey.find_by(id: attributes_for(:meta_key_keywords)[:id]) \
      || create(:meta_key_keywords)
    k1 = create(:keyword, meta_key: meta_key)
    k2 = create(:keyword, meta_key: meta_key)

    @entries = [[k1, k2], [k1], [k1, k2], [k2]].map do |keywords|
      entry = create(:media_entry_with_image_media_file,
                     is_published: true,
                     get_metadata_and_previews: true)
      create(:meta_datum_keywords,
             media_entry: entry, meta_key: meta_key, keywords: keywords)
      entry
    end
  end

  let(:presenter) { described_class.new(@entries.first, nil) }
  let(:rows) { presenter.send(:related_entries_by_shared_keywords) }

  # the per-record loading this presenter used before (the oracle)
  def dump_by_id(pairs)
    Presenter.dump_recur(pairs.to_h)
  end

  it 'finds the related entries' do
    expect(rows.map { |r| r['id'] }).to match_array @entries.drop(1).map(&:id)
  end

  it 'dumps the same keywords, meta keys and vocabularies as loading them one by one' do
    keyword_ids = rows.map { |d| d['keyword_ids'].split(',') }.flatten.uniq
    keywords = keyword_ids.map do |id|
      [id, Presenters::Keywords::KeywordIndex.new(Keyword.find(id))]
    end
    meta_key_ids = keywords.map { |_, k| k.meta_key_id }.uniq
    meta_keys = meta_key_ids.map do |id|
      [id, Presenters::MetaKeys::MetaKeyCommon.new(MetaKey.find(id))]
    end
    vocabularies = meta_keys.map { |_, mk| mk.vocabulary_id }.uniq.map do |id|
      [id, Presenters::Vocabularies::VocabularyCommon.new(Vocabulary.find(id))]
    end

    expect(Presenter.dump_recur(presenter.keywords_by_id)).to eq dump_by_id(keywords)
    expect(presenter.keywords_by_id.keys).to eq keyword_ids
    expect(Presenter.dump_recur(presenter.meta_keys_by_id)).to eq dump_by_id(meta_keys)
    expect(Presenter.dump_recur(presenter.vocabularies_by_id)).to eq dump_by_id(vocabularies)
  end

  it 'dumps the same related entries as loading them one by one, in the same order' do
    wanted = %i(uuid url image_url media_type).map { |k| [k, {}] }.to_h
    expected = rows.map do |dat|
      e = MediaEntry.find_by_id(dat['id'])
      [e.id, Presenters::MediaEntries::MediaEntryIndex.new(e, nil).dump(sparse_spec: wanted)]
    end.to_h

    expect(presenter.entries_by_id).to eq expected
    expect(presenter.entries_by_id.keys).to eq expected.keys
  end

  it 'raises RecordNotFound when a related record is missing' do
    allow(presenter).to receive(:related_entries_by_shared_keywords)
      .and_return([{ 'id' => SecureRandom.uuid, 'keyword_ids' => SecureRandom.uuid }])
    expect { presenter.entries_by_id }.to raise_error ActiveRecord::RecordNotFound
    expect { presenter.keywords_by_id }.to raise_error ActiveRecord::RecordNotFound
  end
end
