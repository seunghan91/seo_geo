# frozen_string_literal: true

require_relative "../../support/dummy_base"

module Dummy
  class Application < Rails::Application
    SeoGeoDummyBase.apply(self, root: File.expand_path("..", __dir__))
  end
end
