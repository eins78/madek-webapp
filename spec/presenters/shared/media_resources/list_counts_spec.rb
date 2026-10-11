require 'spec_helper'

# MADEK_PERF_LIST_COUNTS (app/lib/perf/list_counts.rb): unset/sync = upstream,
# `async`/`none` skip the list COUNT for anonymous visitors on lists that opt in
# with `count_deferrable: true`.
describe Presenters::Shared::MediaResource::MediaResources do
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

  def sql_during
    queries = []
    callback = ->(*, payload) { queries << payload[:sql] }
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { yield }
    queries
  end

  def count_queries(queries)
    queries.select { |q| q =~ /SELECT\s+COUNT\s*\(/i }
  end

  let(:entries) do
    Array.new(3) do
      FactoryBot.create(:media_entry,
                        responsible_user: FactoryBot.create(:user),
                        get_metadata_and_previews: true)
    end
  end
  let(:user) { nil }
  let(:scope) do
    MediaEntry.where(id: entries.map(&:id)).viewable_by_user_or_public(user)
  end
  let(:list_conf) { { per_page: 2 } }
  let(:presenter_args) { { count_deferrable: true } }

  def build(scope_ = scope)
    described_class.new(scope_, user, list_conf: list_conf, **presenter_args)
  end

  shared_examples 'upstream (sync) list' do
    it 'counts in the request and keeps the upstream pagination' do
      presenter = nil
      queries = sql_during { presenter = build }
      expect(count_queries(queries)).not_to be_empty
      expect(presenter.pagination).to eq(
        prev: nil, next: { page: 2 }, total_count: 3, total_pages: 2)
      # every key of the upstream pagination, in order, nothing else
      expect(presenter.pagination.keys).to eq [:prev, :next, :total_count, :total_pages]
      expect(presenter.any?).to be true
      expect(presenter.empty?).to be false
    end
  end

  context 'MADEK_PERF_LIST_COUNTS unset' do
    it_behaves_like 'upstream (sync) list'
  end

  context 'MADEK_PERF_LIST_COUNTS=sync' do
    let(:mode) { 'sync' }
    it_behaves_like 'upstream (sync) list'
  end

  context 'MADEK_PERF_LIST_COUNTS=bogus (unknown value counts as sync)' do
    let(:mode) { 'bogus' }
    it_behaves_like 'upstream (sync) list'
  end

  %w(async none).each do |deferred_mode|
    context "MADEK_PERF_LIST_COUNTS=#{deferred_mode}" do
      let(:mode) { deferred_mode }

      context 'anonymous, main list (count_deferrable: true)' do
        it 'runs no COUNT and leaves the total out' do
          presenter = nil
          queries = sql_during do
            presenter = build
            expect(presenter.any?).to be true
            expect(presenter.empty?).to be false
          end
          expect(count_queries(queries)).to be_empty
          expect { presenter.dump }.not_to raise_error
          expect(presenter.pagination).to eq(
            prev: nil, next: { page: 2 }, total_count: nil, total_pages: nil,
            count_mode: deferred_mode)
          expect(presenter.resources.length).to be 2
        end

        it 'answers `any?`/`empty?` with one memoized EXISTS' do
          presenter = build
          queries = sql_during do
            3.times { presenter.any? && presenter.empty? }
          end
          expect(queries.length).to be 1
          expect(queries.first).to match(/LIMIT/i)
          expect(count_queries(queries)).to be_empty
        end

        it 'paginates by prev/next on the last page' do
          presenter = described_class.new(
            scope, user, list_conf: { per_page: 2, page: 2 }, count_deferrable: true)
          expect(presenter.pagination).to include(
            prev: { page: 1 }, next: nil, total_pages: nil)
          expect(presenter.resources.length).to be 1
        end

        it 'handles an empty scope (empty search)' do
          presenter = build(MediaEntry.where(id: []).viewable_by_user_or_public(user))
          expect(presenter.any?).to be false
          expect(presenter.empty?).to be true
          expect(presenter.pagination).to include(prev: nil, next: nil, total_pages: nil)
        end
      end

      context 'anonymous, list[count]=true' do
        let(:list_conf) { { per_page: 2, count: true } }

        it(deferred_mode == 'async' ? 'counts (the deferred request)' : 'still runs no COUNT') do
          presenter = nil
          queries = sql_during { presenter = build }
          if deferred_mode == 'async'
            expect(count_queries(queries)).not_to be_empty
            expect(presenter.pagination).to eq(
              prev: nil, next: { page: 2 }, total_count: 3, total_pages: 2,
              count_mode: 'async')
          else
            expect(count_queries(queries)).to be_empty
            expect(presenter.pagination).to include(total_count: nil, total_pages: nil)
          end
        end
      end

      context 'logged-in user' do
        let(:user) { FactoryBot.create(:user) }
        it_behaves_like 'upstream (sync) list'
      end

      context 'list that does not opt in (relation lists, dashboards)' do
        let(:presenter_args) { {} }
        it_behaves_like 'upstream (sync) list'
      end

      context 'with_count: false (unchanged upstream output)' do
        let(:presenter_args) { { count_deferrable: true, with_count: false } }

        it 'keeps total_pages 0 and adds no count_mode' do
          presenter = build
          expect(presenter.pagination).to eq(
            prev: nil, next: { page: 2 }, total_count: nil, total_pages: 0)
          expect(presenter.any?).to be true
        end
      end
    end
  end
end

describe 'MADEK_PERF_LIST_COUNTS opt-in per call site' do
  around do |example|
    old = ENV['MADEK_PERF_LIST_COUNTS']
    ENV['MADEK_PERF_LIST_COUNTS'] = 'async'
    begin
      example.run
    ensure
      old.nil? ? ENV.delete('MADEK_PERF_LIST_COUNTS') : ENV['MADEK_PERF_LIST_COUNTS'] = old
    end
  end

  let(:owner) { FactoryBot.create(:user) }
  let(:parent) do
    FactoryBot.create(:collection, responsible_user: owner, get_metadata_and_previews: true)
  end
  let(:child) do
    FactoryBot.create(:collection, responsible_user: owner, get_metadata_and_previews: true)
  end
  let(:entry) do
    FactoryBot.create(:media_entry, responsible_user: owner, get_metadata_and_previews: true)
  end

  before do
    parent.collections << child
    parent.media_entries << entry
  end

  def scopes_for(collection, user)
    { highlighted_media_entries:
        collection.highlighted_media_entries.viewable_by_user_or_public(user),
      highlighted_collections:
        collection.highlighted_collections.viewable_by_user_or_public(user),
      child_media_resources:
        collection.child_media_resources.viewable_by_user_or_public(user),
      parent_collections:
        collection.parent_collections.viewable_by_user_or_public(user),
      sibling_collections:
        collection.sibling_collections.viewable_by_user_or_public(user),
      child_collections:
        collection.collections.viewable_by_user_or_public(user) }
  end

  it 'defers the set children list (main list) for anonymous visitors' do
    presenter = Presenters::Collections::CollectionShow.new(
      parent, nil, scopes_for(parent, nil), list_conf: {})
    pagination = presenter.child_media_resources.pagination
    expect(pagination[:count_mode]).to eq 'async'
    expect(pagination[:total_count]).to be_nil
    expect(pagination[:total_pages]).to be_nil
  end

  it 'keeps counting the set children list for logged-in users' do
    presenter = Presenters::Collections::CollectionShow.new(
      parent, owner, scopes_for(parent, owner), list_conf: {})
    pagination = presenter.child_media_resources.pagination
    expect(pagination).not_to have_key(:count_mode)
    expect(pagination[:total_count]).to eq 2
  end

  it 'keeps counting relation lists (tab counts, hover stacks)' do
    relations = Presenters::Collections::CollectionRelations.new(
      parent, nil, scopes_for(parent, nil), list_conf: {})
    expect(relations.child_collections.pagination[:total_count]).to eq 1
    expect(relations.child_collections.pagination).not_to have_key(:count_mode)
    expect(relations.parent_collections.pagination[:total_count]).to eq 0
    expect(relations.sibling_collections.pagination[:total_count]).to eq 0
  end

  it 'defers keyword, person and vocabulary content lists' do
    keyword = FactoryBot.create(:meta_datum_keywords, media_entry: entry).keywords.first
    keyword_list = Presenters::Keywords::KeywordShow.new(
      nil, keyword, 'entries', {}, nil).resources
    expect(keyword_list.pagination[:count_mode]).to eq 'async'
    expect(keyword_list.any?).to be true

    vocabulary_list = Presenters::Vocabularies::VocabularyContents.new(
      keyword.meta_key.vocabulary, nil, {}, 'entries', nil).resources
    expect(vocabulary_list.pagination[:count_mode]).to eq 'async'
    expect(vocabulary_list.any?).to be true

    person = FactoryBot.create(:person)
    FactoryBot.create(:meta_datum_people, media_entry: entry, people: [person])
    person_list = Presenters::People::PersonShow.new(person, nil, nil, {}, nil).resources
    expect(person_list.pagination[:count_mode]).to eq 'async'
    expect(person_list.pagination[:total_count]).to be_nil
  end
end
