# frozen_string_literal: true

# Cookie de sessão de um domínio. É a conta inteira do dono: nunca sai em log,
# em resposta de API nem em `inspect`.
#
# O payload é armazenado no SQLite de forma CIFRADA via Active Record
# Encryption. As chaves ficam fora do repositório (credenciais do Rails /
# `config/enCRYPTION...` ou variáveis de ambiente gerenciadas pelo deploy);
# a filtragem em `inspect` e `filter_attributes` é defesa adicional, não o
# controle primário — o banco em si não contém o token legível.
class BrowserSessionCookie < ApplicationRecord
  self.filter_attributes = [:payload]

  encrypts :payload

  validates :domain, presence: true, uniqueness: true
  validates :payload, presence: true
  validates :expires_at, presence: true

  def inspect
    "#<BrowserSessionCookie domain=#{domain.inspect} expires_at=#{expires_at.inspect} payload=[FILTRADO]>"
  end
end
