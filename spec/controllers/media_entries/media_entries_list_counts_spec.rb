require 'spec_helper'

# MADEK_PERF_LIST_COUNTS (app/lib/perf/list_counts.rb) on the entries index,
# the main list that controllers opt in with `count_deferrable: true`.
describe MediaEntriesController do
  let(:mode) { nil }

  around do |example|
    old = ENV['MADEK_PERF_LIST_COUNTS']
    mode.nil? ? ENV.delete('MADEK_PERF_LIST_COUNTS') : ENV['MADEK_PERF_LIST_COUNTS'] = mode
    begin
      example.run
    ensure
      old.nil? ? ENV.delete('MADEK_PERF_LIST_COUNTS') : ENV['MADEK_PERF_LIST_COUNTS'] = old
    end
  end

  let(:user) { FactoryBot.create(:user) }

  before do
    3.times do
      FactoryBot.create(:media_entry,
                        responsible_user: FactoryBot.create(:user),
                        get_metadata_and_previews: true)
    end
  end

  # everything the index would count, for any data the DB already holds
  let(:public_total) { MediaEntry.viewable_by_user_or_public(nil).count }
  let(:per_page) { 2 }

  def get_index(list: {}, session: {}, sparse: nil)
    params = { list: { per_page: per_page }.merge(list), format: :json }
    params[:___sparse] = sparse.to_json if sparse
    get(:index, params: params, session: session)
    expect(response.status).to be 200
    JSON.parse(response.body).deep_symbolize_keys
  end

  shared_examples 'upstream pagination' do |session_user|
    it 'has the total in the page' do
      body = get_index(session: session_user ? { user_id: user.id } : {})
      pagination = body[:pagination]
      # the presenter dump omits nil values: page 1 has no `prev` key (same as upstream)
      expect(pagination.keys).to eq [:next, :total_count, :total_pages]
      if session_user
        expect(pagination[:total_count]).to be_a Integer
      else
        expect(pagination[:total_count]).to eq public_total
        expect(pagination[:total_pages]).to eq((public_total.to_f / per_page).ceil)
      end
    end
  end

  context 'MADEK_PERF_LIST_COUNTS unset' do
    it_behaves_like 'upstream pagination', false
  end

  context 'MADEK_PERF_LIST_COUNTS=async' do
    let(:mode) { 'async' }

    it 'anonymous: page without total, prev/next intact' do
      body = get_index
      # nil values (prev, total_count, total_pages) are omitted by the presenter dump
      expect(body[:pagination]).to eq(next: { page: 2 }, count_mode: 'async')
      expect(body[:resources].length).to be per_page
      expect(body[:any?]).to be true
      expect(body[:empty?]).to be false
    end

    it 'anonymous: `list[count]=true` with ___sparse returns the total' do
      body = get_index(list: { count: 'true' }, sparse: { pagination: {} })
      expect(body.keys).to eq [:pagination]
      expect(body[:pagination]).to include(
        total_count: public_total,
        total_pages: (public_total.to_f / per_page).ceil,
        count_mode: 'async')
    end

    it 'anonymous: empty search still responds' do
      body = get_index(list: { filter: { search: 'no-such-term-zzz' }.to_json })
      expect(body[:resources]).to eq []
      expect(body[:pagination].values_at(:prev, :next, :total_pages)).to all(be_nil)
      expect(body[:pagination][:count_mode]).to eq 'async'
      expect(body[:empty?]).to be true
    end

    context 'logged-in' do
      it_behaves_like 'upstream pagination', true
    end
  end

  context 'MADEK_PERF_LIST_COUNTS=none' do
    let(:mode) { 'none' }

    it 'anonymous: no total, also not with `list[count]=true`' do
      [{}, { count: 'true' }].each do |list|
        pagination = get_index(list: list)[:pagination]
        expect(pagination.values_at(:total_count, :total_pages)).to all(be_nil)
        expect(pagination[:count_mode]).to eq 'none'
        expect(pagination[:next]).to eq(page: 2)
      end
    end

    context 'logged-in' do
      it_behaves_like 'upstream pagination', true
    end
  end
end
