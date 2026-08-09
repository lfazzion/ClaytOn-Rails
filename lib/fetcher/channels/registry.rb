# frozen_string_literal: true

require "digest"
require "yaml"

module Fetcher
  module Channels
    # Raiz de toda falha de canal. O `ExtractService` faz `rescue` nesta classe, e
    # é por isso que ela mora aqui e não no canal: o registro carrega os canais
    # sob demanda, então um `rescue Channels::Youtube::NoTranscript` levantaria
    # NameError enquanto o arquivo do canal ainda não foi lido.
    class Error < StandardError; end

    # Resolve qual canal atende uma URL. Duas entradas porque nem todo canal é
    # reconhecível pelo host: feed só se identifica pelo content-type.
    #
    # O canal resolvido pode devolver nil em `call` — content-type é palpite, não
    # veredito. Quem confirma é o canal, olhando o conteúdo.
    module Registry
      CONFIG_FILE = "channels.yml"

      class << self
        def for_host(host)
          return nil unless enabled?

          name = config.fetch("hosts", {}).find do |suffix, _channel|
            host == suffix || host.to_s.end_with?(".#{suffix}")
          end&.last
          name && resolve(name)
        end

        def for_content_type(content_type)
          return nil unless enabled?

          bare = content_type.to_s.split(";").first.to_s.strip.downcase
          name = config.fetch("content_types", {})[bare]
          name && resolve(name)
        end

        # Entra na chave de cache: mudar o roteamento tem que invalidar o que foi
        # gravado pelo roteamento antigo, senão a mesma URL serve resposta de um
        # caminho que não existe mais.
        def fingerprint
          @fingerprint ||= Digest::SHA1.hexdigest(raw_config_text)[0, 8]
        end

        def reset_config!
          @config = nil
          @fingerprint = nil
        end

        private

        def enabled?
          ENV.fetch("EXTRACT_CHANNELS", "1") != "0"
        end

        def config
          @config ||= begin
            data = YAML.safe_load(raw_config_text) || {}
            {
              "hosts"         => normalize(data["hosts"]),
              "content_types" => normalize(data["content_types"])
            }
          end
        end

        def raw_config_text
          path = Rails.root.join("config/#{CONFIG_FILE}")
          File.exist?(path) ? File.read(path) : ""
        end

        def normalize(hash)
          Hash(hash).transform_keys { |k| k.to_s.downcase }
                    .transform_values(&:to_s)
        end

        def resolve(name)
          const = name.to_s.camelize
          require_relative name.to_s
          Fetcher::Channels.const_get(const)
        rescue LoadError, NameError => e
          Rails.logger.error "[Fetcher::Channels::Registry] canal #{name.inspect} não carregou: #{e.class}: #{e.message}"
          nil
        end
      end
    end
  end
end
