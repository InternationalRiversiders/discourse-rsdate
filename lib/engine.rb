# frozen_string_literal: true
module ::DiscourseRsdate
  class Engine < ::Rails::Engine
    engine_name "discourse-rsdate"
    isolate_namespace ::DiscourseRsdate
    config.root = File.expand_path("..", __dir__)
  end
end
