# frozen_string_literal: true

module Internal
  # POST /internal/extract — extração de conteúdo para o reader do Hermes.
  #
  #   Authorization: Bearer <INTERNAL_EXTRACT_TOKEN>
  #   {"urls": ["https://..."], "max_chars": 15000}
  #
  # Resposta 200:
  #   {"results": [{"requested_url": ..., "url": ..., "title": ..., "content": ...,
  #                 "raw_content": ..., "engine": "static"|"chrome", "rendered": bool,
  #                 "metadata": {...}, "error": null}]}
  #
  # `requested_url` é a chave de pareamento do chamador: `url` muda em redirect,
  # então só a URL pedida casa o resultado com o pedido.
  #
  # `rendered: false` significa que o JavaScript da página NÃO rodou — o conteúdo
  # veio só do fetch estático. O reader precisa disso para declarar leitura
  # possivelmente incompleta em vez de afirmar como se fosse completa.
  #
  # Falha de uma URL vira `error` dentro do array — nunca 500 no lote inteiro.
  class ExtractController < ActionController::API
    MAX_URLS    = 10
    CONCURRENCY = (ENV["EXTRACT_CONCURRENCY"] || 4).to_i.clamp(1, 8)

    before_action :authenticate!

    def create
      urls = Array(params[:urls])

      return render_error("informe ao menos uma url", :bad_request) if urls.empty?
      unless urls.all? { |url| url.is_a?(String) && url.present? }
        return render_error("urls deve ser uma lista de strings não vazias", :bad_request)
      end

      if urls.size > MAX_URLS
        return render json: {
          error: "máximo de #{MAX_URLS} urls por chamada (recebidas #{urls.size}) — divida o lote",
          max_urls: MAX_URLS,
          received: urls.size
        }, status: :bad_request
      end

      render json: { results: extract_all(urls) }
    end

    private

    def extract_all(urls)
      max_chars = params[:max_chars]
      results = Array.new(urls.size)
      queue = Queue.new
      urls.each_with_index { |url, index| queue << [url, index] }

      workers = [CONCURRENCY, urls.size].min
      threads = Array.new(workers) do
        Thread.new do
          loop do
            url, index = begin
              queue.pop(true)
            rescue ThreadError
              break
            end
            results[index] = Rails.application.executor.wrap do
              ::Fetcher::ExtractService.call(url, max_chars: max_chars)
            end
          end
        end
      end
      threads.each(&:join)

      results
    end

    def authenticate!
      return render_error("endpoint não configurado (INTERNAL_EXTRACT_TOKEN ausente)", :service_unavailable) if token.blank?
      return if valid_bearer?

      render_error("não autorizado", :unauthorized)
    end

    def valid_bearer?
      presented = request.authorization.to_s[/\ABearer\s+(.+)\z/i, 1].to_s
      return false if presented.empty?

      ActiveSupport::SecurityUtils.secure_compare(presented, token)
    end

    def token
      ENV["INTERNAL_EXTRACT_TOKEN"].to_s
    end

    def render_error(message, status)
      render json: { error: message }, status: status
    end
  end
end
