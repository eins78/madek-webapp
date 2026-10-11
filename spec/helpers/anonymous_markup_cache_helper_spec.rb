require 'spec_helper'

describe AnonymousMarkupCacheHelper do
  let(:store) { ActiveSupport::Cache::MemoryStore.new }
  let(:path) { '/explore' }
  let(:props) { { resources: [{ uuid: 'abc', title: 'Title' }] } }
  let(:component) { 'Views.explore.partials.ThumbnailResourceList' }

  before :each do
    helper.extend(UiHelper)
    allow(Rails).to receive(:cache).and_return(store)
    allow(helper).to receive(:current_user).and_return(nil)
    allow(helper).to receive(:form_authenticity_token).and_return('SECRET-TOKEN')
    allow(helper.request).to receive(:path).and_return(path)
    allow(helper.request).to receive(:original_fullpath).and_return("#{path}?x=1")
    # no server rendering in specs: the "markup" is the props it was given
    @renders = 0
    allow(helper).to receive(:react_component) do |name, props, opts|
      @renders += 1
      "<div data-name=\"#{name}\" data-prerender=\"#{opts[:prerender]}\">" \
        "#{props.to_json}</div>".html_safe
    end
    controller.params = ActionController::Parameters.new({})
  end

  def render_cached(props_hash = props)
    helper.react_cached_for_anonymous('root-list/latest', component) { props_hash }
  end

  it 'renders without the CSRF token and with the path as `for_url`' do
    html = render_cached
    expect(html).not_to include 'SECRET-TOKEN'
    expect(html).to include '"authToken":null'
    expect(html).to include "\"for_url\":\"#{path}\""
    expect(html).to be_html_safe
  end

  it 'stores the markup and serves it on the next request without rendering' do
    first = render_cached
    expect(render_cached).to eq first
    expect(@renders).to eq 1
  end

  it 'keys on the props: other props give other markup' do
    first = render_cached
    other = render_cached(resources: [{ uuid: 'def', title: 'Other' }])
    expect(other).not_to eq first
    expect(other).to include 'Other'
  end

  it 'does not store unrendered markup (`?___norender=1`)' do
    controller.params = ActionController::Parameters.new(___norender: '1')
    html = render_cached
    expect(html).to include 'data-prerender="false"'

    controller.params = ActionController::Parameters.new({})
    expect(render_cached).to include 'data-prerender="true"'
  end

  it 'does not cache for logged-in users and keeps their token' do
    allow(helper).to receive(:current_user).and_return(double('User'))
    expect(store).not_to receive(:write)
    html = render_cached
    expect(html).to include 'SECRET-TOKEN'
    expect(html).to include "\"for_url\":\"#{path}?x=1\""
  end

  it 'does not store markup when server rendering fell back to the client' do
    helper.request.env[AnonymousMarkupCacheHelper::SSR_FALLBACK_ENV_KEY] = true
    render_cached
    helper.request.env.delete(AnonymousMarkupCacheHelper::SSR_FALLBACK_ENV_KEY)
    render_cached
    render_cached
    expect(@renders).to eq 2
  end

  it 'keeps the token for plain `react` calls' do
    html = helper.react(component, props)
    expect(html).to include 'SECRET-TOKEN'
  end
end
