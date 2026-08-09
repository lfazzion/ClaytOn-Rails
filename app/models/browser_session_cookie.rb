# frozen_string_literal: true

# Cookie de sessão de um domínio. É a conta inteira do dono: nunca sai em log,
# em resposta de API nem em `inspect`.
class BrowserSessionCookie < ApplicationRecord
  self.filter_attributes = [:payload]

  validates :domain, presence: true, uniqueness: true
  validates :payload, presence: true
  validates :expires_at, presence: true

  def self.filtered_attributes
    %w[payload]
  end

  def inspect
    "#<BrowserSessionCookie domain=#{domain.inspect} expires_at=#{expires_at.inspect} payload=[FILTRADO]>"
  end
end
