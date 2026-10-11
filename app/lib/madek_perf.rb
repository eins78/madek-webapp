# Opt-in performance toggles (MADEK_PERF_*), all off by default = upstream behaviour.
# Each toggle is documented where it is used (grep MADEK_PERF_).
module MadekPerf
  TRUE_VALUES = %w(1 true yes on).freeze

  def self.on?(name)
    TRUE_VALUES.include?(ENV["MADEK_PERF_#{name.to_s.upcase}"].to_s.strip.downcase)
  end

  def self.value(name, default)
    ENV["MADEK_PERF_#{name.to_s.upcase}"].presence || default
  end
end
