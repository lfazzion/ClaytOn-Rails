# frozen_string_literal: true

# Migration: migrate legacy plaintext payloads to encrypted payloads.
#
# Active Record Encryption is configured via the Rails credentials / env
# secrets — NEVER committed to the repository. This migration reads each
# legacy plaintext JSON payload directly from the database, re-saves the
# same record so the `encrypts :payload` declaration on the model serializes
# the value through the configured encryption keys, and fails atomically
# if any payload cannot be parsed or re-encrypted.
class EncryptBrowserSessionCookiePayloads < ActiveRecord::Migration[8.1]
  # Active Record Encryption requer que a coluna do banco esteja marcada com
  # `encrypt: true` no schema para que o tipo cifrado seja aplicado na leitura
  # e escrita. Sem `change_column ... encrypt: true`, o `encrypts :payload` no
  # modelo falha em runtime com TypedColumnNotInTable ou grava texto-cifrado em
  # coluna comum sem a tag de versão — corrompendo silenciosamente.
  def up
    # NOTE (13/08, medido): `change_column ... encrypt: true` NÃO existe no
    # Rails 8.1 (ArgumentError: Unknown key :encrypt) — a criptografia é
    # declarada pelo `encrypts :payload` no modelo, que aplica o tipo cifrado
    # na leitura/escrita independente do schema. Esta migration só re-salva
    # os registros legados para que o `encrypts` serialize o valor cifrado.

    say_with_time "EncryptBrowserSessionCookiePayloads — re-encrypting existing rows" do
      # Habilita temporariamente o suporte a dados não cifrados para permitir
      # que `BrowserSessionCookie.find` carregue o registro legado sem falhar
      # na tentativa de descriptografar o plaintext antes do re-salvamento.
      previous_support = ActiveRecord::Encryption.config.support_unencrypted_data
      ActiveRecord::Encryption.config.support_unencrypted_data = true

      begin
        rows = connection.select_all("SELECT id, payload FROM browser_session_cookies").to_a
        rows.each do |row|
          raw = row["payload"]

          # Payloads legados devem ser JSON válido; caso contrário, a migration
          # falha atomicamente para o operador inspecionar e corrigir manualmente.
          begin
            JSON.parse(raw.to_s)
          rescue JSON::ParserError => e
            raise ActiveRecord::IrreversibleMigration,
                  "Falha ao parsear payload legado do id=#{row['id']}: #{e.message}"
          end

          record = BrowserSessionCookie.find(row["id"])
          record.payload = raw.to_s
          # payload_will_change!: valor lido (plaintext) == valor atribuído →
          # dirty tracking não marca e o save NÃO re-criptografa. Forçar a
          # re-serialização (medido 13/08 — sem isso a migration é no-op).
          record.payload_will_change!
          record.save!
        end
      ensure
        ActiveRecord::Encryption.config.support_unencrypted_data = previous_support
      end
    end
  end

  def down
    # O down migration não pode decriptar para plaintext de forma determinística
    # em todos os cenários de perda de chave; a coluna permanece criptografada.
    # A coluna era originalmente `:text` (plaintext) — reverte o tipo de schema
    # mas não consegue reverter os dados, por isso mantém o aviso abaixo.
    change_column :browser_session_cookies, :payload, :text
    raise ActiveRecord::IrreversibleMigration,
          "Coluna payload revirada para texto plano, mas dados legados não podem " \
          "ser decriptados sem as chaves originais. Este é um migration de segurança."
  end
end
