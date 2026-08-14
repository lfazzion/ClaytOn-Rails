# frozen_string_literal: true

require 'test_helper'
require_relative '../../../lib/scraping/fetch_pacer'

class FetchPacerTest < ActiveSupport::TestCase
  setup do
    Rails.cache.clear
  end

  test '1st call does not sleep and writes timestamp to Rails.cache' do
    t0 = 1000.0
    Time.stubs(:now).returns(Time.at(t0))
    Scraping::FetchPacer.expects(:pacer_sleep).never

    Scraping::FetchPacer.wait('youtube.com', range: 8..20)

    assert_equal 1000.0, Rails.cache.read('fetch_pacer:youtube.com')
  end

  test '2nd call immediate with range 1..1 sleeps remainder' do
    t0 = 1000.0
    Time.stubs(:now).returns(Time.at(t0))
    Scraping::FetchPacer.wait('youtube.com', range: 1..1)

    t1 = 1000.2
    Time.stubs(:now).returns(Time.at(t1))
    Scraping::FetchPacer.expects(:pacer_sleep).with { |dur| (dur - 0.8).abs < 0.01 }

    Scraping::FetchPacer.wait('youtube.com', range: 1..1)
  end

  test 'call after interval elapsed does not sleep' do
    t0 = 1000.0
    Time.stubs(:now).returns(Time.at(t0))
    Scraping::FetchPacer.wait('youtube.com', range: 8..20)

    # 30 seconds later (interval max is 20)
    t1 = 1030.0
    Time.stubs(:now).returns(Time.at(t1))
    Scraping::FetchPacer.expects(:pacer_sleep).never

    Scraping::FetchPacer.wait('youtube.com', range: 8..20)

    assert_equal 1030.0, Rails.cache.read('fetch_pacer:youtube.com')
  end

  test 'hosts have independent cache keys' do
    t0 = 1000.0
    Time.stubs(:now).returns(Time.at(t0))
    Scraping::FetchPacer.wait('youtube.com', range: 8..20)

    # Calling for twitter.com immediately is 1st call for twitter.com -> should not sleep
    Scraping::FetchPacer.expects(:pacer_sleep).never
    Scraping::FetchPacer.wait('twitter.com', range: 8..20)

    assert_equal 1000.0, Rails.cache.read('fetch_pacer:youtube.com')
    assert_equal 1000.0, Rails.cache.read('fetch_pacer:twitter.com')
  end

  # Rodada 2 (sol 13/08): release_pacer_lock só remove o lock se o token for
  # exatamente o do dono (compare-delete). Com FileStore (testes), o melhor
  # possível sem CAS: verificação de igualdade exata antes do delete.
  test 'release_pacer_lock não remove lock de outro dono (FileStore)' do
    Rails.cache.write('fetch_pacer:lock:test', 'token_antigo', expires_in: 30)
    Scraping::FetchPacer.release_pacer_lock('fetch_pacer:lock:test', 'token_novo')
    assert_equal 'token_antigo', Rails.cache.read('fetch_pacer:lock:test'),
                 "lock de outro dono não deve ser removido"

    Scraping::FetchPacer.release_pacer_lock('fetch_pacer:lock:test', 'token_antigo')
    assert_nil Rails.cache.read('fetch_pacer:lock:test'),
               "token do dono casa — lock deve ser removido"
  end
end
