# frozen_string_literal: true

require 'test_helper'
require_relative '../../lib/scraping/fetch_pacer'

class FetchPacerLockTtlTest < ActiveSupport::TestCase
  def setup
    @host = 'example.com'
    @lock_key = "fetch_pacer:lock:#{@host}"
    @cache_key = "fetch_pacer:#{@host}"
    @token = 'abcdef01'
    Rails.cache.clear
    SecureRandom.stubs(:hex).returns(@token)
  end

  # ── ACHADO 2 (P2): o lock tem TTL fixo de 30s, mas `range` pode produzir uma
  # espera > 30s (ex.: range: 31..31 dorme 31s). O lock expira durante o pacing
  # e um segundo worker entra em paralelo, quebrando a serialização. ──
  test 'lock TTL covers the largest interval in range (no expiry mid-pacing)' do
    captured = {}
    Rails.cache.stubs(:write)
                  .with { |*args, **kwargs| captured[:expires_in] = kwargs[:expires_in] if args[0] == @lock_key; true }
                  .returns(true)
    Rails.cache.stubs(:read).with(@lock_key).returns(@token)
    Rails.cache.stubs(:read).with(@cache_key).returns(nil) # sem last_fetch => sem sleep
    Rails.cache.stubs(:delete).with(@lock_key)

    Scraping::FetchPacer.wait(@host, range: 31..31)

    assert captured[:expires_in], 'o write do lock deve passar expires_in'
    assert_operator captured[:expires_in], :>, 31,
                    "TTL do lock (#{captured[:expires_in]}) deve exceder range.max (31s), "\
                    'senão expira durante o pacing de 31s e outro worker entra em paralelo'
  end

  # Regressão: para um range pequeno o TTL continua cobrindo range.max (não
  # regredimos ao diminuir o lock).
  test 'lock TTL for small range stays at least range.max (no regression)' do
    captured = {}
    Rails.cache.stubs(:write)
                  .with { |*args, **kwargs| captured[:expires_in] = kwargs[:expires_in] if args[0] == @lock_key; true }
                  .returns(true)
    Rails.cache.stubs(:read).with(@lock_key).returns(@token)
    Rails.cache.stubs(:read).with(@cache_key).returns(nil)
    Rails.cache.stubs(:delete).with(@lock_key)

    Scraping::FetchPacer.wait(@host, range: 8..20)

    assert_operator captured[:expires_in], :>=, 20
  end

  # ── ACHADO G (P3, sol 13/08): LOCK_TTL = 30 ficou sem uso. Usá-lo como PISO
  # do TTL do lock, garantindo que nunca caia abaixo de 30s independentemente
  # de range.max. ──
  test 'lock TTL uses LOCK_TTL (30) as a floor even for empty range' do
    captured = {}
    Rails.cache.stubs(:write)
                  .with { |*args, **kwargs| captured[:expires_in] = kwargs[:expires_in] if args[0] == @lock_key; true }
                  .returns(true)
    Rails.cache.stubs(:read).with(@lock_key).returns(@token)
    Rails.cache.stubs(:read).with(@cache_key).returns(nil)
    Rails.cache.stubs(:delete).with(@lock_key)

    # range vazio (max = 0) => TTL deve respeitar o piso LOCK_TTL, não 0+margin
    Scraping::FetchPacer.wait(@host, range: 0..0)

    assert_operator captured[:expires_in], :>=, Scraping::FetchPacer::LOCK_TTL,
                    "TTL do lock (#{captured[:expires_in]}) deve respeitar o piso LOCK_TTL (#{Scraping::FetchPacer::LOCK_TTL})"
  end

  # ── ACHADO D (P2, sol 13/08): os testes só verificavam TTL e stubavam
  # read/delete, sem exercitar a disputa de token no unlock. Este teste é
  # determinístico: simula que, entre a aquisição e a liberação, um worker
  # concorrente assumiu o lock (token diferente). O unlock NÃO deve apagar o
  # lock novo — ele deve permanecer com o token do novo dono. ──
  test 'lock is NOT released when token changed between acquire and release' do
    other_token = 'newownert0'
    delete_called = false
    Rails.cache.stubs(:write)
                  .with { |*args, **kwargs| args[0] == @lock_key; true }
                  .returns(true) # aquisição bem-sucedida com @token
    # No ensure, o read do lock retorna o token do NOVO dono (concorrência):
    Rails.cache.stubs(:read).with(@lock_key).returns(other_token)
    Rails.cache.stubs(:read).with(@cache_key).returns(nil) # sem last_fetch => sem sleep
    Rails.cache.stubs(:delete).with(@lock_key) { delete_called = true }

    Scraping::FetchPacer.wait(@host, range: 8..20)

    refute delete_called,
           'o unlock não deve apagar o lock quando o token mudou — o lock do ' \
           'novo dono deve permanecer intacto'
  end
end
