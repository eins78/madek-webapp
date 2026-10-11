# Request-scoped memo for presenter lookups that are the same for every item
# of a list (contexts, context keys, vocabulary visibility per user).
# `ActiveSupport::CurrentAttributes` is reset by the Rails executor around
# every request (and job), so nothing leaks between requests or users.
class PresenterRequestMemo < ActiveSupport::CurrentAttributes
  attribute :store

  def self.fetch(*key)
    self.store ||= {}
    return store[key] if store.key?(key)
    store[key] = yield
  end
end
