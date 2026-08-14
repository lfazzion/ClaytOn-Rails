# frozen_string_literal: true

require "test_helper"
require "solid_cache"
require_relative "../../../lib/scraping/fetch_pacer"

# Sol rodada 3 (13/08): o caminho de produção do unlock (SolidCache real) não
# era exercitado por nenhum teste — o FileStore do ambiente de teste nunca
# ativava o branch lock_and_write. Este teste usa um SolidCache::Store REAL
# (mesma API do 1.0.10 de produção) e prova que o compare-and-delete atômico
# remove o lock do dono e NÃO destrói o de outro worker.
class FetchPacerSolidCacheReleaseTest < ActiveSupport::TestCase
  def setup
    @store = SolidCache::Store.new(local_cache: false)
    @store.clear rescue nil
    Rails.stubs(:cache).returns(@store)
  end

  def teardown
    Rails.unstub(:cache)
    @store&.clear rescue nil
  end

  test "release_pacer_lock com SolidCache real apaga quando o token casa" do
    @store.write("fetch_pacer:lock:test", "my_token", expires_in: 30)

    Scraping::FetchPacer.release_pacer_lock("fetch_pacer:lock:test", "my_token")

    assert_nil @store.read("fetch_pacer:lock:test"),
               "lock deveria ter sido removido (token confere) — o bloco do lock_and_write deve retornar nil"
  end

  test "release_pacer_lock com SolidCache real NÃO apaga lock de outro worker" do
    @store.write("fetch_pacer:lock:test", "other_token", expires_in: 30)

    Scraping::FetchPacer.release_pacer_lock("fetch_pacer:lock:test", "my_token")

    assert_equal "other_token", @store.read("fetch_pacer:lock:test"),
                 "lock de outro dono deve permanecer intacto"
  end
end
