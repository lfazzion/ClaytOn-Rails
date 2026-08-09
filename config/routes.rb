Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check
  get "health" => "health#show"

  # Endpoint interno de extração (reader do Hermes). Autenticado por bearer
  # token; o binding de rede é o declarado no docker-compose.
  namespace :internal do
    post "extract" => "extract#create"
  end

  # Servidor MCP do reader do Hermes. Endpoint único, POST; o GET é respondido
  # com 405 pelo próprio transporte, que é o que a revisão 2026-07-28 manda.
  match "mcp" => "mcp#handle", via: %i[get post delete]
end
