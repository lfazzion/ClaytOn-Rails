# frozen_string_literal: true

# POST /mcp — servidor MCP para o perfil `reader` do Hermes.
#
#   Authorization: Bearer <INTERNAL_MCP_TOKEN>
#
# Token próprio, separado do `/internal/extract`: são capacidades diferentes, e
# revogar uma não pode derrubar a outra. Ausente = 503, nunca aberto.
#
# O protocolo inteiro é do gem `mcp` (dual-era: `initialize` legado e
# `server/discover` moderno no mesmo endpoint). Este controller é só o portão.
#
# Sem `require` de `McpServer`: ele é autoloadable a partir de `lib/mcp_server.rb`.
class McpController < ActionController::API
  before_action :authenticate!

  def handle
    status, headers, corpo = McpServer.app.call(request.env)

    texto = +""
    corpo.each { |pedaco| texto << pedaco }
    corpo.close if corpo.respond_to?(:close)

    headers.each { |chave, valor| response.headers[chave] = valor unless chave.casecmp?("content-length") }
    render plain: texto, status: status, content_type: headers["content-type"] || "application/json"
  end

  private

  def authenticate!
    return render_error("endpoint não configurado (INTERNAL_MCP_TOKEN ausente)", :service_unavailable) if token.blank?
    return if valid_bearer?

    render_error("não autorizado", :unauthorized)
  end

  def valid_bearer?
    apresentado = request.authorization.to_s[/\ABearer\s+(.+)\z/i, 1].to_s
    return false if apresentado.empty?

    ActiveSupport::SecurityUtils.secure_compare(apresentado, token)
  end

  def token
    ENV["INTERNAL_MCP_TOKEN"].to_s
  end

  def render_error(mensagem, status)
    render json: { error: mensagem }, status: status
  end
end
