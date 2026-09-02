ENV['RAILS_ENV'] ||= 'test'
require_relative '../config/environment'
require 'rails/test_help'
require 'webmock/minitest'
require 'factory_bot_rails'
require 'mocha/minitest'

WebMock.disable_net_connect!(allow_localhost: true)

class ActiveSupport::TestCase
  fixtures :all
  include FactoryBot::Syntax::Methods
end

# Isolamento de estado por teste (02/09/2026): o teto de buscas pagas e o
# estado jitter/backoff vivem em Thread.current[:cleitin_*]; sem reset, testes
# na MESMA thread vazam contagem entre testes/arquivos e envenenam os seguintes
# (CI #163/#164). Precisa valer para ActiveSupport::TestCase E Minitest::Test
# puro (os *_pure_test herdam Minitest::Test direto).
module SearxngSearchStateIsolation
  def before_setup
    SearchApiRouter.reset_paid_search_count!
    WebSearchTool.reset_searxng_turn_state!
    super if defined?(super)
  end
end
ActiveSupport::TestCase.include SearxngSearchStateIsolation
Minitest::Test.include SearxngSearchStateIsolation
