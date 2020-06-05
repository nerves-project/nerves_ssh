[
  # dialyzer doesn't like start_daemon/3 wrapping the :ssh.daemon call
  # and can only guess the error type of the function. For now, let's
  # just ignore in specific places
  {"lib/nerves_ssh.ex", :pattern_match_cov, 73},
  {"lib/nerves_ssh.ex", :pattern_match_cov, 87},
  {"lib/nerves_ssh.ex", :extra_range, 176}
]
