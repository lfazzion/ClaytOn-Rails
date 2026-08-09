# frozen_string_literal: true

require "test_helper"
require Rails.root.join("lib/fetcher/host_rate_limiter")

class Fetcher::HostRateLimiterTest < ActiveSupport::TestCase
  setup { Rails.cache.clear }

  test "escopos diferentes nao disputam o mesmo contador" do
    4.times { assert_not Fetcher::HostRateLimiter.exceeded?("x.com", max: 4, scope: "mirror") }
    # O balde do espelho esta cheio, mas o da timeline esta intacto.
    assert_not Fetcher::HostRateLimiter.exceeded?("x.com", max: 4, scope: "timeline")
  end

  # CONTROLE: sem escopo, o comportamento antigo continua — o mesmo host disputa
  # o mesmo balde. Sem este controle, o teste acima passaria com um limitador que
  # simplesmente nunca conta nada.
  test "CONTROLE: mesmo escopo estoura no teto" do
    4.times { assert_not Fetcher::HostRateLimiter.exceeded?("x.com", max: 4, scope: "timeline") }
    assert Fetcher::HostRateLimiter.exceeded?("x.com", max: 4, scope: "timeline")
  end

  test "o teto por hora reprova antes do teto por minuto quando estoura" do
    6.times { Fetcher::HostRateLimiter.exceeded?("x.com", max: 100, scope: "timeline", per_hour: 6) }
    assert Fetcher::HostRateLimiter.exceeded?("x.com", max: 100, scope: "timeline", per_hour: 6)
  end

  # CONTROLE: com per_hour folgado, as mesmas 7 chamadas passam — prova que quem
  # reprovou acima foi a janela de hora, e nao a de minuto.
  test "CONTROLE: per_hour folgado deixa as mesmas chamadas passarem" do
    7.times { |i| assert_not Fetcher::HostRateLimiter.exceeded?("x.com", max: 100, scope: "timeline", per_hour: 1000), "chamada #{i}" }
  end
end
