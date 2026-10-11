require 'spec_helper'

describe Presenters::MediaEntries::MediaEntries do
  before :example do
    @user = FactoryBot.create(:user)
    3.times do
      FactoryBot.create(:media_entry,
                        responsible_user: @user, get_metadata_and_previews: true)
    end
  end

  def presenter(list_conf)
    described_class.new(
      MediaEntry.unscoped.where(responsible_user_id: @user.id), @user,
      list_conf: list_conf)
  end

  [0, -3, '0', '-1', 'garbage', ''].each do |value|
    it "uses page 1 for `page: #{value.inspect}`" do
      p = presenter(page: value)
      expect(p.config[:page]).to eq 1
      expect(p.resources.count).to eq 3
      expect(p.pagination[:total_pages]).to eq 1
    end

    it "uses the default per_page for `per_page: #{value.inspect}`" do
      p = presenter(per_page: value)
      expect(p.config[:per_page]).to eq 12
      expect(p.pagination[:total_pages]).to eq 1
    end
  end

  it 'keeps valid values' do
    p = presenter(page: '2', per_page: '2')
    expect(p.config[:page]).to eq 2
    expect(p.config[:per_page]).to eq 2
    expect(p.resources.count).to eq 1
  end
end
