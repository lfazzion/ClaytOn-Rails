# frozen_string_literal: true
#
# MISSÃO C2a (perito, seção C2 — S2-01/S2-04): o bloco "Catálogos populares
# recentes" do Ideias da Semana não pode repetir o mesmo item toda semana.
#
# Verificações exigidas pelo veredito:
#   1. item já enviado NÃO volta no próximo digest (mesmo digest_type + canal);
#   2. item enviado em OUTRO canal / OUTRO digest_type NÃO é suprimido;
#   3. desempate determinístico quando popularity empata (não depende da
#      ordem física do SQLite);
#   4. janela de recência respeitada (item fora da janela não entra);
#   5. fallback declarado: esgotada a janela base, política = janela
#      ampliada (30→60→90d, teto); esgotado o teto, aviso explícito de que
#      não há novidade — nunca repetição em silêncio.
#
# Estado de envio: DigestItemDelivery (tabela própria) — nunca em
# ExternalCatalog (veredito do perito, seção C2, resposta 2).

require 'test_helper'
require_relative '../../app/services/discord_api_client'
require_relative '../../app/services/discord_message_chunker'
require_relative '../../app/jobs/friday_ideation_job'

class FridayIdeationJobC2aTest < ActiveSupport::TestCase
  DIGEST_TYPE = 'friday_ideation'.freeze

  # Margens de 5 dias para os limites das janelas (30/60/90) não virarem
  # fronteira exata e o teste não ficar à mercê do relógio.
  def within_30d_items
    at = 25.days.ago
    [
      create(:external_catalog, source: 'anilist', title: 'AnimeA', popularity: 10.0, created_at: at, updated_at: at),
      create(:external_catalog, source: 'anilist', title: 'AnimeB', popularity: 10.0, created_at: at, updated_at: at),
      create(:external_catalog, source: 'anilist', title: 'AnimeC', popularity: 50.0, created_at: at, updated_at: at)
    ]
  end

  # Executa o job de ponta a ponta (canal fixo via ENV, Discord stubado) e
  # devolve a mensagem enviada — para asserções sobre o conteúdo do bloco.
  #
  # STUB POR SINGLETON OVERRIDE (padrão do repo — ai_router_test.rb:98-110;
  # rodada 2: em Mocha 3.1.0, `stubs(...).returns([...])` devolve o valor cru
  # SEM executar bloco/Proc, e `stubs(...) do ... end` NÃO executa o corpo —
  # por isso o teste via "" em vez da mensagem real). Aqui o chunker passa o
  # texto adiante (pass-through) e o send_message captura a mensagem de
  # verdade; os métodos originais são restaurados no ensure.
  def run_job(channel_id)
    ENV['DISCORD_DIGEST_CHANNEL_ID'] = channel_id
    sent = []

    original_ai   = AiRouter.method(:complete)
    original_chunk = DiscordMessageChunker.method(:chunk)
    original_send  = DiscordApiClient.method(:send_message)

    AiRouter.define_singleton_method(:complete) { |_prompt, **_kwargs| Struct.new(:content).new(nil) }
    DiscordMessageChunker.define_singleton_method(:chunk) { |message, **_kwargs| [message] }
    DiscordApiClient.define_singleton_method(:send_message) { |_channel, msg| sent << msg }

    FridayIdeationJob.new.perform
    sent.join("\n")
  ensure
    ENV.delete('DISCORD_DIGEST_CHANNEL_ID')
    if original_ai
      AiRouter.singleton_class.send(:remove_method, :complete)
      AiRouter.define_singleton_method(:complete, original_ai)
    end
    if original_chunk
      DiscordMessageChunker.singleton_class.send(:remove_method, :chunk)
      DiscordMessageChunker.define_singleton_method(:chunk, original_chunk)
    end
    if original_send
      DiscordApiClient.singleton_class.send(:remove_method, :send_message)
      DiscordApiClient.define_singleton_method(:send_message, original_send)
    end
  end

  # Chaves de entrega (item_key) registradas para este digest+canal. Usa
  # item_key, e não id, porque item_key é a chave estável de entrega que
  # atravessa as tabelas ExternalCatalog e DigestItemDelivery (rodada 2:
  # comparar ids de tabelas distintas só coincidia em banco limpo).
  def delivery_keys(channel_id)
    DigestItemDelivery.where(digest_type: DIGEST_TYPE, channel_id: channel_id,
                             item_type: DigestItemDelivery::ITEM_TYPE_CATALOG).pluck(:item_key)
  end

  test 'C2a-1: item já enviado (mesmo digest_type + canal) não volta no próximo digest' do
    itens = within_30d_items
    run_job('canal_a')
    assert_equal itens.map(&:key).sort, delivery_keys('canal_a').sort

    novo = create(:external_catalog, source: 'anilist', title: 'AnimeNovo', popularity: 99.0,
                 created_at: 2.days.ago, updated_at: 2.days.ago)
    mensagem = run_job('canal_a')

    # Semana 2: o novo item entra; os três da semana 1 NÃO voltam.
    assert_equal (itens + [novo]).map(&:key).sort, delivery_keys('canal_a').sort
    assert_includes mensagem, 'AnimeNovo'
    %w[AnimeA AnimeB AnimeC].each { |t| refute_includes mensagem, t }
  end

  test 'C2a-2: item enviado em outro canal ou outro digest_type não é suprimido indevidamente' do
    itens = within_30d_items
    run_job('canal_a')

    # OUTRO canal: o mesmo item pode ser entregue de novo (não vaza entre canais).
    mensagem_b = run_job('canal_b')
    assert_equal itens.map(&:key).sort, delivery_keys('canal_b').sort
    assert_includes mensagem_b, 'AnimeA'

    # OUTRO digest_type no canal_b: nem inibe a seleção do friday_ideation.
    novo = create(:external_catalog, source: 'anilist', title: 'AnimeNovo', popularity: 99.0,
                 created_at: 2.days.ago, updated_at: 2.days.ago)
    DigestItemDelivery.create!(digest_type: 'weekly_digest', channel_id: 'canal_b',
                               item_type: DigestItemDelivery::ITEM_TYPE_CATALOG,
                               item_key: novo.key, sent_at: Time.current)
    mensagem_c = run_job('canal_b')
    # canal_b JÁ tinha os 3 originais (registrados pela mensagem_b); o
    # weekly_digest do novo NÃO suprime o friday_ideation, então o novo
    # entra somado aos originais (4 chaves). Medido no probe C2a (canal_b
    # final = 3 originais + novo); a rodada original comparava só [novo]
    # por engano, ignorando o acúmulo prévio do canal.
    assert_equal (itens + [novo]).map(&:key).sort, delivery_keys('canal_b')
    assert_includes mensagem_c, 'AnimeNovo'
    %w[AnimeA AnimeB AnimeC].each { |t| refute_includes mensagem_c, t }
  end

  test 'C2a-3: desempate determinístico em popularidade (não depende da ordem do SQLite)' do
    zzz = create(:external_catalog, source: 'anilist', title: 'ZZZ', popularity: 10.0, created_at: 5.days.ago, updated_at: 5.days.ago)
    aaa = create(:external_catalog, source: 'anilist', title: 'AAA', popularity: 10.0, created_at: 1.day.ago, updated_at: 1.day.ago)
    mmm = create(:external_catalog, source: 'anilist', title: 'MMM', popularity: 20.0, created_at: 5.days.ago, updated_at: 5.days.ago)
    topo = create(:external_catalog, source: 'anilist', title: 'P', popularity: 99.0, created_at: 1.day.ago, updated_at: 1.day.ago)

    mensagem = run_job('canal_a')
    assert_equal [topo, mmm, aaa, zzz].map(&:key).sort, delivery_keys('canal_a').sort

    # Ordem exibida: popularidade desc; empate (AAA/ZZZ = 10.0) ⇒ título asc.
    # Determinístico: não depende de como o SQLite devolve a tabela.
    bloco = mensagem[/\*\*Catálogos populares recentes:\*\*(?:.*\n)*/]
    assert bloco, 'bloco de catálogos ausente da mensagem'
    posi = %w[P MMM AAA ZZZ].index_with { |t| bloco.index(t) }
    assert posi.values.all?, "itens ausentes do bloco: #{posi.inspect}"
    assert posi['P'] < posi['MMM'], 'P (99) deve vir antes de MMM (20)'
    assert posi['MMM'] < posi['AAA'], 'MMM (20) deve vir antes do empate 10.0'
    assert posi['AAA'] < posi['ZZZ'], 'empate em 10.0: AAA (título) antes de ZZZ'
  end

  test 'C2a-4: janela de recência respeitada — item fora de todas as janelas não entra' do
    dentro = within_30d_items
    run_job('canal_a')
    assert_equal dentro.map(&:key).sort, delivery_keys('canal_a').sort

    antigo = create(:external_catalog, source: 'anilist', title: 'MuitoAntigo', popularity: 999.0,
                  created_at: 200.days.ago, updated_at: 200.days.ago)
    mensagem = run_job('canal_a')

    # 30d/60d/90d esgotados: item de 200d está fora de qualquer janela da
    # política — nem com popularidade 999 ele entra. Sem nova entrega.
    assert_equal dentro.map(&:key).sort, delivery_keys('canal_a').sort
    refute_includes mensagem, 'MuitoAntigo'
  end

  test 'C2a-5: fallback declarado — janela base esgotada ⇒ janela ampliada; teto esgotado ⇒ aviso, nunca repetição' do
    base = within_30d_items
    meia = create(:external_catalog, source: 'anilist', title: 'AnimeM60', popularity: 30.0,
             created_at: 55.days.ago, updated_at: 55.days.ago)
    fora = create(:external_catalog, source: 'anilist', title: 'AnimeM90', popularity: 30.0,
              created_at: 95.days.ago, updated_at: 95.days.ago)

    run_job('canal_a') # semana 1: envia a base (janela 30d)
    assert_equal base.map(&:key).sort, delivery_keys('canal_a').sort

    mensagem2 = run_job('canal_a')
    # Semana 2: 30d esgotado (tudo já enviado) ⇒ política amplia para 60d:
    # AnimeM60 (55d) entra. AnimeM90 (95d) não entra (fora do teto 90d).
    assert_equal (base + [meia]).map(&:key).sort, delivery_keys('canal_a').sort
    assert_includes mensagem2, 'AnimeM60'
    refute_includes mensagem2, 'AnimeM90'

    mensagem3 = run_job('canal_a')
    # Semana 3: teto 90d esgotado ⇒ fallback declarado: aviso explícito de
    # que não há novidade; nenhum item já enviado volta.
    assert_equal (base + [meia]).map(&:key).sort, delivery_keys('canal_a').sort
    assert_match(/Sem novidade/i, mensagem3)
    %w[AnimeA AnimeB AnimeC AnimeM60 AnimeM90].each { |t| refute_includes mensagem3, "**#{t}**" }
  end

  test 'C2a-6: item_key registrado com outro item_type não entra em sent_item_keys — item_type faz parte do contrato da chave' do
    run_job('canal_a')

    alvo = within_30d_items.first
    # Marca o item_key do alvo com um item_type DIFERENTE do catálogo.
    DigestItemDelivery.create!(digest_type: DIGEST_TYPE, channel_id: 'canal_a',
                               item_type: 'news_article', item_key: alvo.key,
                               sent_at: Time.current)

    # `sent_item_keys` (default item_type = CATALOG) NÃO deve devolver a
    # chave registrada como news_article: esse registro pertence a outro
    # contrato de item_type e não suprime o catálogo.
    keys = DigestItemDelivery.sent_item_keys(digest_type: DIGEST_TYPE, channel_id: 'canal_a')
    refute_includes keys, alvo.key

    # O registro news_article existe de fato (isentando o teste de "chave
    # simplesmente ausente por falha de criação").
    assert_equal 1, DigestItemDelivery.where(item_type: 'news_article').count
  end

  test 'C2a-7: item_type DIFERENTE jamais suprime — a mesma item_key não entregue como catálogo continua elegível' do
    alvo = create(:external_catalog, source: 'anilist', title: 'AnimeSolo', popularity: 99.0,
                 created_at: 2.days.ago, updated_at: 2.days.ago)

    # Registra o item_key do alvo com item_type distinto ANTES de o digest
    # entregá-lo como catálogo. Isso NÃO pode suprimi-lo.
    DigestItemDelivery.create!(digest_type: DIGEST_TYPE, channel_id: 'canal_a',
                               item_type: 'news_article', item_key: alvo.key,
                               sent_at: Time.current)

    mensagem = run_job('canal_a')
    assert_includes mensagem, 'AnimeSolo'
    assert_includes delivery_keys('canal_a'), alvo.key
  end
end