require 'spec_helper'

describe Presenters::MediaEntries::MediaEntryIndex do
  before :each do
    AppSetting.find_or_create_by(id: 0)
    @media_entry = FactoryBot.create(:media_entry)
  end

  describe '#invalid_meta_data' do
    it 'is nil without validating when the user can not edit the entry' do
      expect_any_instance_of(MediaEntry).not_to receive(:valid?)
      presenter = described_class.new(@media_entry, nil)
      expect(presenter.editable).to be false
      expect(presenter.invalid_meta_data).to be_nil
    end

    it 'validates the entry when the user can edit it' do
      presenter = described_class.new(@media_entry, @media_entry.responsible_user)
      expect(presenter.editable).to be true
      expected = (true unless @media_entry.valid?)
      expect(presenter.invalid_meta_data).to eq expected
    end
  end
end
