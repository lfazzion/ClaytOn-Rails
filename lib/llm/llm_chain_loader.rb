# frozen_string_literal: true

require "digest"

module Llm
  # Loader do arquivo de configuração da cadeia de LLM (config/llm_chain.yml),
  # fora do git. Lê a cada chamada de propósito — trocar o arquivo vale SEM
  # restart do bot (requisito do dono: "alteração sem reiniciar").
  #
  # Responsabilidades:
  #   1. Validar o YAML (safe_load, sem aliases, schema versionado `version: 1`).
  #   2. Garantir primary OBRIGATÓRIO; fallback é um mapa OU null.
  #   3. Manter um LAST-KNOWN-GOOD POR PROCESSO (estado de classe, indexado por
  #      caminho): depois de uma carga válida, um YAML inválido/parcial só loga
  #      UMA vez por digest e devolve o último bom. No PRIMEIRO boot, YAML
  #      inválido/ausente => cadeia vazia (quem chama trata), NUNCA silencia com
  #      um default inventado.
  #
  # O loader NÃO resolve chaves de provedor, NÃO registra modelos e NÃO monta
  # Links — isso é ModelChain.links. Aqui só há parsing + validação + last-known-good.
  class LlmChainLoader
    SCHEMA_VERSION = 1

    # Erro de configuração do YAML. Subclasse de StandardError de propósito:
    # não é RuntimeError genérico, para o chamador poder distinguir "config
    # quebrada" de "erro de rota".
    class ConfigError < StandardError; end

    # Estado de last-known-good POR PROCESSO, indexado por caminho. `links`
    # instancia um loader novo a cada chamada, então o estado NÃO pode viver na
    # instância — tem de ser de classe para sobreviver entre chamadas.
    @state = {}  # path => { last_good:, last_digest:, warned: {} }
    @state_mutex = Mutex.new

    class << self
      attr_reader :state, :state_mutex
    end

    # `logger` é injetável (testes passam um capturador; produção passa
    # Rails.logger). `path` é o caminho do arquivo.
    def initialize(path:, logger: nil)
      @path = path
      @logger = logger
    end

    # Devolve o hash normalizado { primary: {...}, fallback: {...} | nil } ou
    # `nil` quando a cadeia tem de ficar vazia (primeiro boot sem config válida,
    # ou arquivo ausente). YAML inválido APÓS carga válida devolve o last-known-good.
    def load
      # Falha de leitura (permissão, diretório no lugar do arquivo, erro de IO)
      # NÃO pode derrubar o turno: é tratada como last-known-good (igual a um
      # YAML corrompido), nunca como exceção que sobe até o chamador.
      raw = read_raw
      return last_good if raw == :unreadable
      return nil if raw.nil?

      digest = Digest::SHA256.hexdigest(raw)
      return last_good if last_good && digest == last_digest

      parsed = parse_and_validate(raw)
      write_state(last_good: parsed, last_digest: digest, warned: {})
      parsed
    rescue ConfigError => e
      if last_good
        log_once(digest, "config/llm_chain.yml inválido (#{e.message}) — mantendo última cadeia válida")
        last_good
      else
        log_once("firstboot:#{digest}",
                 "config/llm_chain.yml inválido no primeiro boot (#{e.message}) — cadeia vazia")
        nil
      end
    end

    # Lê o arquivo. Devolve:
    #   - nil          => caminho ausente/inviável E sem LKG (cadeia vazia)
    #   - :unreadable  => falha de leitura (permissão/diretório/IO): mantém LKG
    #   - String       => conteúdo lido
    # SystemCallError (Errno::EACCES, Errno::EISDIR, ...) e IOError em LEITURA
    # viram :unreadable — NUNCA derrubam o turno (Sol R1-A, achado 1).
    def read_raw
      return nil unless @path && File.exist?(@path)

      # `File.exist?` é verdadeiro para diretórios; File.read de um diretório
      # levanta Errno::EISDIR. Capturamos como leitura inviável.
      begin
        File.read(@path)
      rescue SystemCallError, IOError => e
        if last_good
          log_once(:read_error, "falha de leitura de config/llm_chain.yml " \
                                "(#{e.class}: #{e.message}) — mantendo última cadeia válida")
          :unreadable
        else
          log_once("firstboot:read_error",
                   "falha de leitura de config/llm_chain.yml no primeiro boot " \
                   "(#{e.class}: #{e.message}) — cadeia vazia")
          nil
        end
      end
    end

    private

    def last_good
      self.class.state_mutex.synchronize { self.class.state.dig(@path, :last_good) }
    end

    def last_digest
      self.class.state_mutex.synchronize { self.class.state.dig(@path, :last_digest) }
    end

    def write_state(last_good:, last_digest:, warned:)
      self.class.state_mutex.synchronize do
        self.class.state[@path] = { last_good: last_good, last_digest: last_digest, warned: warned }
      end
    end

    # safe_load sem aliases: o YAML de config Nunca deve executar código nem
    # referenciar objetos. `permitted_classes: []` + `aliases: false` é o
    # contrato mínimo de segurança para um arquivo editável em produção.
    def parse_and_validate(raw)
      data = begin
        YAML.safe_load(raw, permitted_classes: [], aliases: false, symbolize_names: true)
      rescue Psych::Exception => e
        # Psych::AliasesNotEnabled / Psych::SyntaxError / Psych::DisallowedClass
        # NÃO são ConfigError. Embrulha para o chamador ver um único tipo de erro
        # de configuração (e o last-known-good funcionar para YAML corrompido).
        raise ConfigError, "YAML inválido: #{e.message}"
      end
      raise ConfigError, "não é um Hash" unless data.is_a?(Hash)

      version = data[:version]
      raise ConfigError, "version ausente ou inválido (esperado #{SCHEMA_VERSION})" unless version == SCHEMA_VERSION

      chat = data[:chat]
      raise ConfigError, "chave `chat` ausente" if chat.nil?
      raise ConfigError, "`chat` não é um Hash" unless chat.is_a?(Hash)

      primary = chat[:primary]
      raise ConfigError, "`chat.primary` obrigatório" if primary.nil?
      validate_link!(primary, "primary")

      fallback = chat[:fallback]
      if !fallback.nil?
        raise ConfigError, "`chat.fallback` deve ser um mapa ou null" unless fallback.is_a?(Hash)
        validate_link!(fallback, "fallback")
      end

      { primary: primary, fallback: fallback }
    end

    def validate_link!(link, onde)
      raise ConfigError, "`#{onde}` não é um mapa" unless link.is_a?(Hash)
      raise ConfigError, "`#{onde}.provider` obrigatório" if link[:provider].nil?
      raise ConfigError, "`#{onde}.model` obrigatório" if link[:model].nil?

      # Validação de TIPOS ANTES de usar os valores (Sol R1-A, achado 1):
      # `provider: {}` produzia NoMethodError em to_sym; agora é ConfigError.
      provider = link[:provider]
      raise ConfigError, "`#{onde}.provider` deve ser String ou Symbol não vazio" \
        unless provider.is_a?(String) || provider.is_a?(Symbol)
      raise ConfigError, "`#{onde}.provider` não pode ser vazio" if provider.to_s.strip.empty?

      model = link[:model]
      raise ConfigError, "`#{onde}.model` deve ser String não vazia" unless model.is_a?(String)
      raise ConfigError, "`#{onde}.model` não pode ser vazio" if model.to_s.strip.empty?

      # label: String ou null
      if !link[:label].nil? && !link[:label].is_a?(String)
        raise ConfigError, "`#{onde}.label` deve ser String ou null"
      end

      # effort: String ou null
      if !link[:effort].nil? && !link[:effort].is_a?(String)
        raise ConfigError, "`#{onde}.effort` deve ser String ou null"
      end

      # params: Hash ou null; se params.tags presente => Array não vazio de String
      # no formato aceito (`user=` prefix, exigido pelo gateway Nous).
      params = link[:params]
      if !params.nil?
        raise ConfigError, "`#{onde}.params` deve ser um mapa ou null" unless params.is_a?(Hash)
        if params.key?(:tags)
          tags = params[:tags]
          raise ConfigError, "`#{onde}.params.tags` deve ser um Array não vazio" \
            unless tags.is_a?(Array) && !tags.empty?
          raise ConfigError, "`#{onde}.params.tags` deve ser Array de String" \
            unless tags.all? { |t| t.is_a?(String) }
          raise ConfigError, "`#{onde}.params.tags` fora do formato aceito (esperado prefixo user=)" \
            unless tags.all? { |t| t.to_s.start_with?("user=") }
        end
      end

      # `symbolize_names: true` simboliza CHAVES, não VALORES: `provider: nous`
      # chega como String. Normaliza para Símbolo aqui, de modo que primary E
      # fallback saiam iguais do parse. Só agora é seguro, pois os tipos foram
      # validados acima.
      link[:provider] = link[:provider].to_sym
      # label e effort são opcionais (caem no default); params é opcional.
    end

    # Log único por identidade: evita inundar o log a cada chamada de `links`
    # (que roda toda vez que o bot monta um chat) enquanto o arquivo ruim persiste.
    def log_once(ident, msg)
      self.class.state_mutex.synchronize do
        st = self.class.state[@path] ||= {}
        warned = st[:warned] ||= {}
        return if warned[ident]
        warned[ident] = true
      end
      log_warn msg
    end

    def log_warn(msg)
      if @logger.respond_to?(:warn)
        @logger.warn "[LlmChainLoader] #{msg}"
      elsif @logger.respond_to?(:call)
        @logger.call(msg)
      else
        warn msg
      end
    end
  end
end