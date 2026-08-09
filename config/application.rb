require_relative 'boot'

require 'rails'
require 'active_model/railtie'
require 'active_record/railtie'
require 'active_job/railtie'
require 'action_controller/railtie'

Bundler.require(*Rails.groups)

module CleitinBot
  class Application < Rails::Application
    config.load_defaults 8.0
    config.api_only = false
    config.session_store :cookie_store, key: '_cleitin_bot_session'
    config.middleware.use ActionDispatch::Cookies
    config.middleware.use config.session_store
    config.autoload_lib(ignore: %w[assets tasks scraping llm])

    # Tools têm múltiplas classes por arquivo — require explícito necessário
    Rails.autoloaders.main.ignore(Rails.root.join("app/tools"))

    # DatabaseSelector middleware requer uma role :reading via `connects_to`, que nunca foi
    # configurada (não há réplica — SQLite single-file). Habilitá-lo sem essa role faz
    # ActiveRecord::Base.connection falhar em requests GET/HEAD ("No database connection
    # defined for reading"). Desativado até que uma réplica real seja implementada.
  end
end
