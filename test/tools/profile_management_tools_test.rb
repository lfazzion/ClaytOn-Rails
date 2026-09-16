# frozen_string_literal: true

require 'test_helper'
require 'timeout'
require_relative '../../app/tools/tool_base'
require_relative '../../app/tools/profile_management_tools'

class ProfileManagementToolsTest < ActiveSupport::TestCase
  setup do
    @orig_owner_ids = ENV['DISCORD_OWNER_IDS']
    ENV['DISCORD_OWNER_IDS'] = '12345'
    Thread.current[:cleitin_actor] = { user_id: '12345', username: 'dono' }
    Thread.current[:cleitin_turn] = 'turn_setup'
    Rails.cache.clear
  end

  teardown do
    ENV['DISCORD_OWNER_IDS'] = @orig_owner_ids
    Thread.current[:cleitin_actor] = nil
    Thread.current[:cleitin_turn] = nil
  end

  # ── 1. Autorização (fail-closed) ─────────────────────────────────────────────

  test 'tools de escrita recusam execução sem cleitin_actor' do
    Thread.current[:cleitin_actor] = nil

    tools = [
      AddProfileTool.new,
      SetProfileMonitoringTool.new,
      RemoveProfileTool.new,
      PromoteProspectTool.new
    ]

    tools.each do |tool|
      result = tool.execute(platform: 'twitter', handle: 'teste', identifier: '1', status: 'paused', discovered_profile_id: 1)
      assert_equal :error, result[:status], "#{tool.class} deveria ter falhado por falta de ator"
    end
  end

  test 'tools de escrita recusam execução de ator fora da allowlist' do
    Thread.current[:cleitin_actor] = { user_id: '99999', username: 'intruso' }

    result = AddProfileTool.new.execute(platform: 'twitter', handle: 'teste')
    assert_equal :error, result[:status]
  end

  test 'tools de escrita recusam execução sem DISCORD_OWNER_IDS' do
    ENV['DISCORD_OWNER_IDS'] = nil

    result = AddProfileTool.new.execute(platform: 'twitter', handle: 'teste')
    assert_equal :error, result[:status]
  end

  # ── 2. AddProfileTool ─────────────────────────────────────────────────────────

  test 'add_profile em youtube com metadata válido cria perfil e enfileira job' do
    metadata = {
      channel_id: 'UC_REAL_CHANNEL_ID',
      title: 'Canal Real YouTube',
      description: 'Descrição do canal',
      subscriber_count: 50_000,
      avatar_url: 'https://example.com/avatar.jpg'
    }

    ScrapingServices::YoutubeScraperService.stubs(:extract_channel_metadata)
                                           .with('https://www.youtube.com/@canalx', timeout: 8)
                                           .returns(metadata)
    ScrapeYoutubeJob.expects(:perform_later).with(kind_of(Integer)) do |profile_id|
      @captured_profile_id = profile_id
      true
    end.returns(true)

    tool = AddProfileTool.new
    result = tool.execute(platform: 'youtube', handle: 'canalx')

    assert_equal :success, result[:status]
    assert_equal 'canalx', result[:data][:username]

    profile = SocialProfile.find_by(platform: 'youtube', platform_username: 'canalx')
    assert_not_nil profile
    assert_equal 'UC_REAL_CHANNEL_ID', profile.platform_user_id
    assert_equal 'active', profile.monitoring_status
    assert_equal 'Canal Real YouTube', profile.display_name
    assert_equal profile.id, @captured_profile_id
  end

  test 'add_profile em youtube com URL colada extrai handle e cria' do
    metadata = {
      channel_id: 'UC_URL_ID',
      title: 'Canal via URL',
      subscriber_count: 10_000
    }

    ScrapingServices::YoutubeScraperService.stubs(:extract_channel_metadata)
                                           .with('https://www.youtube.com/@canalurl', timeout: 8)
                                           .returns(metadata)
    ScrapeYoutubeJob.expects(:perform_later).with(kind_of(Integer)) do |profile_id|
      @captured_profile_id = profile_id
      true
    end.returns(true)

    tool = AddProfileTool.new
    result = tool.execute(platform: 'youtube', handle: 'https://www.youtube.com/@CanalUrl')

    assert_equal :success, result[:status]
    assert_equal 'canalurl', result[:data][:username]

    profile = SocialProfile.find_by(platform: 'youtube', platform_username: 'canalurl')
    assert_not_nil profile
    assert_equal profile.id, @captured_profile_id
  end

  test 'add_profile em youtube com metadata nil retorna error e não cria' do
    ScrapingServices::YoutubeScraperService.stubs(:extract_channel_metadata).returns(nil)
    ScrapeYoutubeJob.expects(:perform_later).never

    assert_no_difference 'SocialProfile.count' do
      tool = AddProfileTool.new
      result = tool.execute(platform: 'youtube', handle: 'naoexiste')
      assert_equal :error, result[:status]
    end
  end

  test 'add_profile em instagram cria com pending_validation e enfileira ScrapeInstagramJob' do
    ScrapeInstagramJob.expects(:perform_later).with(kind_of(Integer)).returns(true)

    tool = AddProfileTool.new
    result = tool.execute(platform: 'instagram', handle: 'insta_user')

    assert_equal :success, result[:status]
    profile = SocialProfile.find_by(platform: 'instagram', platform_username: 'insta_user')
    assert_not_nil profile
    assert_equal 'pending_validation', profile.collection_status
    assert_equal 'pending:instagram:insta_user', profile.platform_user_id
  end

  test 'add_profile valida regex de handle por plataforma' do
    tool = AddProfileTool.new

    assert_equal :error, tool.execute(platform: 'youtube', handle: 'va!!do')[:status]
    assert_equal :error, tool.execute(platform: 'twitter', handle: 'user_muito_longo_com_20_chars')[:status]
    assert_equal :error, tool.execute(platform: 'tiktok', handle: '.ponto')[:status]
  end

  test 'add_profile retorna error para plataforma desconhecida' do
    tool = AddProfileTool.new
    result = tool.execute(platform: 'linkedin', handle: 'usuario')
    assert_equal :error, result[:status]
  end

  test 'add_profile com perfil já monitorado retorna already_monitored sem duplicar' do
    existing = create(:social_profile, :twitter, platform_username: 'user_existente')

    assert_no_difference 'SocialProfile.count' do
      tool = AddProfileTool.new
      result = tool.execute(platform: 'twitter', handle: 'User_Existente')
      assert_equal :already_monitored, result[:status]
      assert_equal existing.id, result[:data][:id]
    end
  end

  test 'add_profile em perfil arquivado reativa perfil com status reactivated e desarquiva' do
    profile = create(:social_profile, :twitter, platform_username: 'user_arquivado', archived_at: 1.day.ago, monitoring_status: 'paused')

    tool = AddProfileTool.new
    result = tool.execute(platform: 'twitter', handle: 'User_Arquivado')

    assert_equal :reactivated, result[:status]
    assert_nil profile.reload.archived_at
    assert_equal 'active', profile.monitoring_status
  end

  test 'normalize_handle preserva case de URL youtube /channel/' do
    tool = AddProfileTool.new
    url = 'https://www.youtube.com/channel/UCn8SzhX6Z1qW9_123456789'
    normalized = tool.send(:normalize_handle, url)

    assert_equal 'UCn8SzhX6Z1qW9_123456789', normalized
  end

  test 'add_profile em youtube com URL /channel/ usa id sem downcase para platform_user_id e platform_username' do
    channel_id = 'UCn8SzhX6Z1qW9_123456789'
    metadata = {
      channel_id: channel_id,
      title: 'Canal ID Preservado',
      subscriber_count: 5_000
    }

    ScrapingServices::YoutubeScraperService.expects(:extract_channel_metadata)
                                           .with("https://www.youtube.com/channel/#{channel_id}", timeout: 8)
                                           .returns(metadata)
    ScrapeYoutubeJob.stubs(:perform_later)

    tool = AddProfileTool.new
    result = tool.execute(platform: 'youtube', handle: "https://www.youtube.com/channel/#{channel_id}")

    assert_equal :success, result[:status]

    profile = SocialProfile.find_by(platform: 'youtube', platform_user_id: channel_id)
    assert_not_nil profile
    assert_equal channel_id, profile.platform_user_id
    assert_equal channel_id, profile.platform_username
  end

  test 'add_profile com URL /channel/ cria perfil e build_channel_url monta URL de canal com case correto' do
    channel_id = 'UCn8SzhX6Z1qW9_123456789'
    metadata = {
      channel_id: channel_id,
      title: 'Canal ID Preservado',
      subscriber_count: 5_000
    }

    ScrapingServices::YoutubeScraperService.stubs(:extract_channel_metadata)
                                           .with("https://www.youtube.com/channel/#{channel_id}", timeout: 8)
                                           .returns(metadata)
    ScrapeYoutubeJob.stubs(:perform_later)

    tool = AddProfileTool.new
    result = tool.execute(platform: 'youtube', handle: "https://www.youtube.com/channel/#{channel_id}")

    assert_equal :success, result[:status]
    profile = SocialProfile.find_by(platform: 'youtube', platform_user_id: channel_id)
    assert_not_nil profile
    assert_equal channel_id, profile.platform_username

    assert_equal "https://www.youtube.com/channel/#{channel_id}",
                 ScrapeYoutubeJob.new.send(:build_channel_url, profile)
  end

  test 'normalize_handle preserva case de channel ID informado bare (sem URL)' do
    tool = AddProfileTool.new

    assert_equal 'UCn8SzhX6Z1qW9_123456789', tool.send(:normalize_handle, 'UCn8SzhX6Z1qW9_123456789')
    assert_equal 'UCn8SzhX6Z1qW9_123456789', tool.send(:normalize_handle, '@UCn8SzhX6Z1qW9_123456789')
  end

  test 'add_profile em youtube passa timeout 8s para extract_channel_metadata e trata Timeout::Error' do
    ScrapingServices::YoutubeScraperService.expects(:extract_channel_metadata)
                                           .with('https://www.youtube.com/@timeout_channel', timeout: 8)
                                           .raises(Timeout::Error.new('execution expired'))

    tool = AddProfileTool.new
    result = tool.execute(platform: 'youtube', handle: 'timeout_channel')

    assert_equal :error, result[:status]
    assert_equal 'validação demorou — tente de novo', result[:reason]
  end

  test 'add_profile trata RecordInvalid e retorna erro amigável' do
    ScrapingServices::YoutubeScraperService.stubs(:extract_channel_metadata).returns({ title: 'X' })
    SocialProfile.stubs(:create!).raises(ActiveRecord::RecordInvalid.new(SocialProfile.new.tap { |p| p.errors.add(:platform_username, 'inválido') }))

    tool = AddProfileTool.new
    result = tool.execute(platform: 'youtube', handle: 'canal_invalid')
    assert_equal :error, result[:status]
    assert_includes result[:reason], 'Erro ao salvar'
  end

  # ── 3. SetProfileMonitoringTool ─────────────────────────────────────────────

  test 'set_profile_monitoring pausa por handle e retoma por id' do
    profile = create(:social_profile, :twitter, platform_username: 'monitored_user', monitoring_status: 'active')

    tool = SetProfileMonitoringTool.new

    # Pausa por handle
    res1 = tool.execute(identifier: 'monitored_user', status: 'paused')
    assert_equal :success, res1[:status]
    assert_equal 'paused', profile.reload.monitoring_status

    # Retoma por id
    res2 = tool.execute(identifier: profile.id.to_s, status: 'active')
    assert_equal :success, res2[:status]
    assert_equal 'active', profile.reload.monitoring_status
  end

  test 'set_profile_monitoring com status active em perfil arquivado limpa archived_at' do
    profile = create(:social_profile, :twitter, platform_username: 'archived_monit', archived_at: 2.days.ago, monitoring_status: 'paused')

    tool = SetProfileMonitoringTool.new
    result = tool.execute(identifier: profile.platform_username, status: 'active')

    assert_equal :success, result[:status]
    assert_nil profile.reload.archived_at
    assert_equal 'active', profile.monitoring_status
  end

  test 'set_profile_monitoring recusa status inválido' do
    profile = create(:social_profile, :twitter, platform_username: 'some_user')

    tool = SetProfileMonitoringTool.new
    result = tool.execute(identifier: profile.platform_username, status: 'invalido')
    assert_equal :error, result[:status]
  end

  test 'set_profile_monitoring retorna erro para perfil inexistente' do
    tool = SetProfileMonitoringTool.new
    result = tool.execute(identifier: 'fantasma', status: 'paused')
    assert_equal :error, result[:status]
  end

  # ── 4. RemoveProfileTool ──────────────────────────────────────────────────────

  # 4.1 — Confirmação de uso único (ator + ação + alvo + expiração)
  test 'remove_profile sem confirm_token retorna preview e NÃO destrói' do
    profile = create(:social_profile, :twitter, platform_username: 'preview_only')

    tool = RemoveProfileTool.new
    res = tool.execute(identifier: 'preview_only')

    assert_equal :confirmation_required, res[:status]
    assert_includes res[:reason], 'Confirme'
    assert SocialProfile.exists?(profile.id)
    assert res[:data][:confirm_token].present?
    assert res[:data][:expires_at].present?
    assert_equal 'preview_only', res[:data][:target][:platform_username]
  end

  test 'remove_profile com confirm_token de outro ator NÃO autoriza' do
    profile = create(:social_profile, :twitter, platform_username: 'target_actor')

    # Cria confirmação com ator original
    tool = RemoveProfileTool.new
    preview = tool.execute(identifier: 'target_actor')
    token = preview[:data][:confirm_token]

    # Tenta usar com outro ator (dono na allowlist — o portão de dono passa;
    # a checagem de CONFIRMAÇÃO de ator que deve recusar)
    Thread.current[:cleitin_actor] = { user_id: '67890', username: 'dono2' }
    ENV['DISCORD_OWNER_IDS'] = '12345,67890'
    res = tool.execute(identifier: 'target_actor', confirm_token: token)

    assert_equal :error, res[:status]
    assert_includes res[:reason], 'ator'
    assert SocialProfile.exists?(profile.id)
  end

  test 'remove_profile com confirm_token de outro alvo NÃO autoriza' do
    profile_a = create(:social_profile, :twitter, platform_username: 'target_a')
    profile_b = create(:social_profile, :twitter, platform_username: 'target_b')

    tool = RemoveProfileTool.new
    preview = tool.execute(identifier: 'target_a')
    token = preview[:data][:confirm_token]

    # Tenta usar token do target_a no target_b
    res = tool.execute(identifier: 'target_b', confirm_token: token)

    assert_equal :error, res[:status]
    assert_includes res[:reason], 'alvo'
    assert SocialProfile.exists?(profile_a.id)
    assert SocialProfile.exists?(profile_b.id)
  end

  test 'remove_profile com confirm_token de ação diferente NÃO autoriza (vínculo de ação)' do
    profile = create(:social_profile, :twitter, platform_username: 'action_bind')

    tool = RemoveProfileTool.new
    preview = tool.execute(identifier: 'action_bind')
    token = preview[:data][:confirm_token]

    # Corrompe o vínculo: o token passa a apontar para outra ação (a
    # implementação grava/leve a convenção JSON com chaves string; manter a
    # convenção ao manipular — ver teste de expiração).
    cache_key = "remove_profile_confirm:#{token}"
    raw = Rails.cache.read(cache_key)
    if raw.is_a?(String)
      hash = JSON.parse(raw)
      hash['action'] = 'add_profile'
      Rails.cache.write(cache_key, JSON.generate(hash))
    else
      Rails.cache.write(cache_key, raw.merge(action: 'add_profile'))
    end

    res = tool.execute(identifier: 'action_bind', confirm_token: token)

    assert_equal :error, res[:status]
    assert_includes res[:reason], 'ação diferente'
    # O alvo NÃO é destruído: o vínculo de ação protege contra regressão.
    assert SocialProfile.exists?(profile.id)
    # E o token foi consumido (claim): não serve nem para nova tentativa.
    refute Rails.cache.exist?(cache_key)
  end

  test 'remove_profile com confirm_token expirado NÃO autoriza' do
    profile = create(:social_profile, :twitter, platform_username: 'expired_target')

    tool = RemoveProfileTool.new
    preview = tool.execute(identifier: 'expired_target')
    token = preview[:data][:confirm_token]

    # Expira o token manipulando o cache. O value gravado pelo app é a
    # convenção que o app lê de volta (r3: string JSON, chaves STRING —
    # JSON.parse devolve chaves string). Manter a convenção na manipulação:
    # mergear com chave símbolo gera DUAS chaves 'expires_at' no Hash
    # (string + símbolo) e o JSON sai com chave duplicada.
    cache_key = "remove_profile_confirm:#{token}"
    raw = Rails.cache.read(cache_key)
    if raw.is_a?(String)
      hash = JSON.parse(raw)
      hash['expires_at'] = 1.minute.ago.iso8601
      Rails.cache.write(cache_key, JSON.generate(hash))
    else
      Rails.cache.write(cache_key, raw.merge(expires_at: 1.minute.ago.iso8601))
    end

    res = tool.execute(identifier: 'expired_target', confirm_token: token)

    assert_equal :error, res[:status]
    assert_includes res[:reason], 'expir'
    assert SocialProfile.exists?(profile.id)
  end

  test 'remove_profile com confirm_token válido EXECUTA destroy! uma única vez (consumo provado)' do
    profile = create(:social_profile, :twitter, platform_username: 'valid_confirm')

    tool = RemoveProfileTool.new
    preview = tool.execute(identifier: 'valid_confirm')
    token = preview[:data][:confirm_token]

    # Primeira execução com token válido
    res1 = tool.execute(identifier: 'valid_confirm', confirm_token: token)
    assert_equal :success, res1[:status]
    assert_equal 'removed', res1[:data][:status]
    refute SocialProfile.exists?(profile.id)

    # Prova o CONSUMO mesmo quando a segunda chamada é legítima: o alvo
    # reexiste (perfil do mesmo handle criado de novo), então a 2ª chamada
    # passa em find_profile e CHEGA na validação do token — e é o token
    # consumido (claim) que a recusa, não o alvo ausente.
    profile2 = create(:social_profile, :twitter, platform_username: 'valid_confirm')
    res2 = tool.execute(identifier: 'valid_confirm', confirm_token: token)

    assert_equal :error, res2[:status]
    assert_includes res2[:reason], 'Confirmação inválida ou inexistente'
    assert SocialProfile.exists?(profile2.id), 'o alvo reexistente NÃO pode ser destruído com token já consumido'
  end

  test 'duas chamadas concorrentes com o MESMO token executam destroy! exatamente uma vez (consumo atômico)' do
    profile = create(:social_profile, :twitter, platform_username: 'race_confirm')

    tool = RemoveProfileTool.new
    preview = tool.execute(identifier: 'race_confirm')
    token = preview[:data][:confirm_token]
    cache_key = "remove_profile_confirm:#{token}"
    assert Rails.cache.exist?(cache_key)

    # Duas threads reais correm para consumir o MESMO token. claim_token é
    # um delete atômico com retorno conferido: em ambos os stores reais só
    # UM delete consegue apagar a chave (FileStore: File.delete — o SO
    # garante exclusão única; SolidCache: DELETE...WHERE no SQLite — 1ª
    # transação apaga, a 2ª recebe 0 linhas). Os demais 3 caminhos
    # (diferentes atores, alvo inexistente, claim vencido) NÃO executam
    # destroy!.
    barrier = Queue.new
    2.times { barrier << true }
    results = Array.new(2)
    threads = 2.times.map do |i|
      Thread.new do
        Thread.current[:cleitin_actor] = { user_id: '12345', username: 'dono' }
        barrier.pop # as duas threads só prosseguem juntas — a corrida é real
        results[i] = tool.execute(identifier: 'race_confirm', confirm_token: token)
      end
    end
    threads.each(&:join)

    execs = results.count { |r| r[:status] == :success }
    rejeitadas = results.count { |r| r[:status] == :error && r[:reason].include?('Confirmação inválida ou inexistente') }

    assert_equal 1, execs, 'duas execuções = destruição dupla (bloqueador)'
    assert_equal 1, rejeitadas, 'exatamente uma rejeição por token consumido'
    refute SocialProfile.exists?(profile.id)
    refute Rails.cache.exist?(cache_key), 'o token deve ter saído do cache'
  end

  test 'remove_profile por handle remove perfil de verdade (destroy!) após confirmação válida' do
    profile = create(:social_profile, :twitter, platform_username: 'to_remove_hndl')

    tool = RemoveProfileTool.new
    preview = tool.execute(identifier: 'to_remove_hndl')
    token = preview[:data][:confirm_token]

    res = tool.execute(identifier: 'to_remove_hndl', confirm_token: token)

    assert_equal :success, res[:status]
    assert_equal 'removed', res[:data][:status]
    refute SocialProfile.exists?(profile.id)
  end

  test 'remove_profile por ID numerico remove perfil de verdade após confirmação válida' do
    profile = create(:social_profile, :twitter, platform_username: 'to_remove_id')

    tool = RemoveProfileTool.new
    preview = tool.execute(identifier: profile.id.to_s)
    token = preview[:data][:confirm_token]

    res = tool.execute(identifier: profile.id.to_s, confirm_token: token)

    assert_equal :success, res[:status]
    assert_equal 'removed', res[:data][:status]
    refute SocialProfile.exists?(profile.id)
  end

  test 'remove_profile por ID numerico remove perfil de verdade' do
    profile = create(:social_profile, :twitter, platform_username: 'to_remove_id2')

    tool = RemoveProfileTool.new
    preview = tool.execute(identifier: profile.id.to_s)
    token = preview[:data][:confirm_token]

    res = tool.execute(identifier: profile.id.to_s, confirm_token: token)

    assert_equal :success, res[:status]
    assert_equal 'removed', res[:data][:status]
    refute SocialProfile.exists?(profile.id)
  end

  test 'remove_profile recusa execucao para nao-dono' do
    profile = create(:social_profile, :twitter, platform_username: 'protected_user')
    Thread.current[:cleitin_actor] = { user_id: '99999', username: 'intruso' }

    tool = RemoveProfileTool.new
    res = tool.execute(identifier: 'protected_user')

    assert_equal :error, res[:status]
    assert_includes res[:reason], 'Ação restrita ao dono do bot'
    assert SocialProfile.exists?(profile.id)
  end

  test 'remove_profile retorna erro para perfil inexistente' do
    tool = RemoveProfileTool.new
    res = tool.execute(identifier: 'fantasma')

    assert_equal :error, res[:status]
    assert_includes res[:reason], 'Perfil não encontrado'
  end

  test 'remove_profile retorna erro para perfil ambiguo sem plataforma' do
    create(:social_profile, :twitter, platform_username: 'same_handle')
    create(:social_profile, :instagram, platform_username: 'same_handle')

    tool = RemoveProfileTool.new
    res = tool.execute(identifier: 'same_handle')

    assert_equal :error, res[:status]
    assert_includes res[:reason], 'Perfil ambíguo'
  end

  test 'remove_profile remove em cascata posts, profile_snapshots e post_snapshots' do
    profile = create(:social_profile, :twitter, platform_username: 'cascade_user')
    posts = create_list(:social_post, 2, social_profile: profile)
    post_ids = posts.map(&:id)
    create(:profile_snapshot, social_profile: profile)
    posts.each { |post| create(:post_snapshot, social_post: post) }

    profile_id = profile.id

    tool = RemoveProfileTool.new
    preview = tool.execute(identifier: 'cascade_user')
    token = preview[:data][:confirm_token]

    res = tool.execute(identifier: 'cascade_user', confirm_token: token)

    assert_equal :success, res[:status]
    assert_equal 'removed', res[:data][:status]

    refute SocialProfile.exists?(profile_id)
    assert_equal 0, SocialPost.where(social_profile_id: profile_id).count
    assert_equal 0, ProfileSnapshot.where(social_profile_id: profile_id).count
    assert_equal 0, PostSnapshot.where(social_post_id: post_ids).count
  end

  test 'remove_profile desvincula (nullify) DiscoveredProfile associado preservando o registro' do
    profile = create(:social_profile, :twitter, platform_username: 'source_user')
    dp = create(:discovered_profile, source_profile: profile)

    tool = RemoveProfileTool.new
    preview = tool.execute(identifier: 'source_user')
    token = preview[:data][:confirm_token]

    res = tool.execute(identifier: 'source_user', confirm_token: token)

    assert_equal :success, res[:status]
    refute SocialProfile.exists?(profile.id)
    assert DiscoveredProfile.exists?(dp.id)
    assert_nil dp.reload.source_profile_id
  end

  test 'remove_profile rescata RecordNotDestroyed e retorna erro amigavel' do
    profile = create(:social_profile, :twitter, platform_username: 'not_destroyed')

    tool = RemoveProfileTool.new
    preview = tool.execute(identifier: 'not_destroyed')
    token = preview[:data][:confirm_token]
    cache_key = "remove_profile_confirm:#{token}"

    SocialProfile.any_instance.stubs(:destroy!).raises(ActiveRecord::RecordNotDestroyed.new('Failed to destroy', profile))

    res = tool.execute(identifier: 'not_destroyed', confirm_token: token)

    assert_equal :error, res[:status]
    assert_includes res[:reason], 'Erro ao remover'
    # DECISÃO (ressalva 3): em falha do destroy! o token PERMANECE consumido.
    # O claim (delete atômico) acontece ANTES do destroy! — a falha não devolve
    # a chave. O dono precisa pedir uma confirmação NOVA para tentar de novo:
    # em ação destrutiva, reexecução automática pós-falha é mais perigosa que
    # reconfirmação.
    refute Rails.cache.exist?(cache_key), 'token não pode ser liberado após falha do destroy!'
    # O alvo também NÃO pode ser destruído de novo reusando o token morto.
    res2 = tool.execute(identifier: 'not_destroyed', confirm_token: token)
    assert_equal :error, res2[:status]
    assert_includes res2[:reason], 'Confirmação inválida ou inexistente'
    assert SocialProfile.exists?(profile.id), 'o alvo sobrevivente não pode ser destruído com token consumido'
  end

  test 'remove_profile rescata InvalidForeignKey e retorna erro amigavel' do
    profile = create(:social_profile, :twitter, platform_username: 'fk_error_user')

    tool = RemoveProfileTool.new
    preview = tool.execute(identifier: 'fk_error_user')
    token = preview[:data][:confirm_token]
    cache_key = "remove_profile_confirm:#{token}"

    SocialProfile.any_instance.stubs(:destroy!).raises(ActiveRecord::InvalidForeignKey.new('Foreign key violation'))

    res = tool.execute(identifier: 'fk_error_user', confirm_token: token)

    assert_equal :error, res[:status]
    assert_includes res[:reason], 'Erro ao remover'
    # Mesma decisão do teste acima: falha do destroy! NÃO libera o token.
    refute Rails.cache.exist?(cache_key)
    assert SocialProfile.exists?(profile.id)
  end

  test 'remove_profile grava log de auditoria estruturado antes do destroy' do
    profile = create(:social_profile, :twitter, platform_username: 'audit_rm_user')
    create_list(:social_post, 3, social_profile: profile)
    create_list(:profile_snapshot, 2, social_profile: profile)
    profile_id = profile.id
    username = profile.platform_username

    logs = []
    Rails.logger.stubs(:info).with { |msg| logs << msg.to_s; true }

    tool = RemoveProfileTool.new
    preview = tool.execute(identifier: 'audit_rm_user')
    token = preview[:data][:confirm_token]

    res = tool.execute(identifier: 'audit_rm_user', confirm_token: token)

    assert_equal :success, res[:status]
    # O preview grava TAMBÉM um log de auditoria (stage 'preview') — apontar
    # para a linha do EXECUTE (stage 'execute') é o que prova o log antes do
    # destroy com os dados finais do perfil.
    linhas_audit = logs.select { |l| l.include?('[RemoveProfileTool]') }
    capturado = linhas_audit.last
    assert capturado, 'esperava log de auditoria [RemoveProfileTool] (execute)'
    assert_includes capturado, '[RemoveProfileTool]'
    assert_equal 'execute', JSON.parse(capturado.sub(/\A\[RemoveProfileTool\]\s*/, ''))['stage']

    payload = JSON.parse(capturado.sub(/\A\[RemoveProfileTool\]\s*/, ''))
    assert_equal profile_id, payload['id']
    assert_equal username, payload['platform_username']
    assert_equal 3, payload['posts_count']
    assert_equal 2, payload['snapshots_count']
    assert payload.key?('actor')
    refute_nil payload['actor']
  end

  # ── 5. PromoteProspectTool ──────────────────────────────────────────────────

  test 'promote_prospect promove DiscoveredProfile a SocialProfile e enfileira coleta' do
    dp = create(:discovered_profile, platform: 'twitter', username: 'prospect_user', bio: 'Bio do prospecto')

    ScrapeTwitterJob.expects(:perform_later).with(kind_of(Integer)).returns(true)

    tool = PromoteProspectTool.new
    result = tool.execute(discovered_profile_id: dp.id)

    assert_equal :success, result[:status]
    sp = SocialProfile.find_by(platform: 'twitter', platform_username: 'prospect_user')
    assert_not_nil sp
    assert_equal 'Bio do prospecto', sp.bio
    assert_equal 'active', sp.monitoring_status
  end

  test 'promote_prospect valida plataforma e handle regras antes de criar' do
    dp_invalid_plt = create(:discovered_profile, platform: 'linkedin', username: 'prospect_lk')
    tool = PromoteProspectTool.new

    res1 = tool.execute(discovered_profile_id: dp_invalid_plt.id)
    assert_equal :error, res1[:status]
    assert_includes res1[:reason], 'Plataforma inválida'

    dp_invalid_handle = create(:discovered_profile, platform: 'twitter', username: 'user_muito_longo_com_20_chars')
    res2 = tool.execute(discovered_profile_id: dp_invalid_handle.id)
    assert_equal :error, res2[:status]
    assert_includes res2[:reason], 'Handle inválido'
  end

  test 'promote_prospect trata RecordInvalid e retorna erro amigável' do
    dp = create(:discovered_profile, platform: 'twitter', username: 'prospect_err')
    SocialProfile.stubs(:create!).raises(ActiveRecord::RecordInvalid.new(SocialProfile.new.tap { |p| p.errors.add(:platform_username, 'duplicado') }))

    tool = PromoteProspectTool.new
    result = tool.execute(discovered_profile_id: dp.id)
    assert_equal :error, result[:status]
    assert_includes result[:reason], 'Erro ao salvar'
  end

  test 'promote_prospect retorna already_monitored se já existir SocialProfile' do
    create(:social_profile, :twitter, platform_username: 'already_user')
    dp = create(:discovered_profile, platform: 'twitter', username: 'already_user')

    tool = PromoteProspectTool.new
    result = tool.execute(discovered_profile_id: dp.id)

    assert_equal :already_monitored, result[:status]
  end

  test 'promote_prospect retorna error se prospecto não existir' do
    tool = PromoteProspectTool.new
    result = tool.execute(discovered_profile_id: 999_999)
    assert_equal :error, result[:status]
  end

  # ── 6. Corrida de criação (RecordNotUnique) ──────────────────────────────────

  test 'add_profile em race retorna already_monitored com vencedor e sem enqueue duplicado' do
    metadata = {
      channel_id: 'UC_RACE_ID',
      title: 'Canal Race',
      subscriber_count: 1_000
    }
    ScrapingServices::YoutubeScraperService.stubs(:extract_channel_metadata).returns(metadata)

    winner = create(:social_profile, platform: 'youtube', platform_username: 'racechannel',
                                     platform_user_id: 'UC_RACE_ID', display_name: 'Canal Race',
                                     monitoring_status: 'active', collection_status: 'pending',
                                     followers_count: 1_000)

    tool = AddProfileTool.new
    # Primeira chamada (pre-check): nil — nenhum duplicado.
    # Segunda chamada (via find_winner após RecordNotUnique): o vencedor.
    tool.stubs(:find_duplicate).with('youtube', 'racechannel').returns(nil, winner)

    SocialProfile.expects(:create!).raises(ActiveRecord::RecordNotUnique.new('duplicate'))
    ScrapeYoutubeJob.expects(:perform_later).never

    result = tool.execute(platform: 'youtube', handle: 'racechannel')

    assert_equal :already_monitored, result[:status]
    expected = tool.send(:format_profile, winner)
    assert_equal expected, result[:data]
  end

  test 'add_profile em race por platform_user_id com handles diferentes retorna already_monitored com vencedor' do
    metadata = {
      channel_id: 'UC_DIFF_HANDLE_ID',
      title: 'Canal YouTube',
      subscriber_count: 5_000
    }
    ScrapingServices::YoutubeScraperService.stubs(:extract_channel_metadata).returns(metadata)

    winner = create(:social_profile, platform: 'youtube', platform_username: 'handle_antigo',
                                     platform_user_id: 'UC_DIFF_HANDLE_ID', display_name: 'Canal YouTube',
                                     monitoring_status: 'active', collection_status: 'pending',
                                     followers_count: 5_000)

    tool = AddProfileTool.new

    SocialProfile.expects(:create!).raises(ActiveRecord::RecordNotUnique.new('duplicate user_id'))
    ScrapeYoutubeJob.expects(:perform_later).never

    result = tool.execute(platform: 'youtube', handle: 'handle_novo')

    assert_equal :already_monitored, result[:status]
    expected = tool.send(:format_profile, winner)
    assert_equal expected, result[:data]
  end

  test 'promote_prospect em race retorna already_monitored com vencedor e sem enqueue duplicado' do
    dp = create(:discovered_profile, platform: 'twitter', username: 'prospect_race')

    winner = create(:social_profile, platform: 'twitter', platform_username: 'prospect_race',
                                     platform_user_id: 'UC_WIN_ID',
                                     monitoring_status: 'active', collection_status: 'pending_validation')

    tool = PromoteProspectTool.new
    # Primeira chamada (pre-check): nil. Segunda chamada (recovery): winner.
    tool.stubs(:find_duplicate).with('twitter', 'prospect_race').returns(nil, winner)

    SocialProfile.expects(:create!).raises(ActiveRecord::RecordNotUnique.new('duplicate'))
    ScrapeTwitterJob.expects(:perform_later).never

    result = tool.execute(discovered_profile_id: dp.id)

    assert_equal :already_monitored, result[:status]
    expected = tool.send(:format_profile, winner)
    assert_equal expected, result[:data]
  end

  test 'add_profile em race por platform_user_id em perfil arquivado reativa o perfil e retorna reactivated' do
    metadata = {
      channel_id: 'UC_ARCHIVED_HANDLE_ID',
      title: 'Canal YouTube',
      subscriber_count: 5_000
    }
    ScrapingServices::YoutubeScraperService.stubs(:extract_channel_metadata).returns(metadata)

    winner = create(:social_profile, platform: 'youtube', platform_username: 'handle_antigo',
                                     platform_user_id: 'UC_ARCHIVED_HANDLE_ID', display_name: 'Canal YouTube',
                                     monitoring_status: 'paused', archived_at: 1.day.ago)

    tool = AddProfileTool.new

    SocialProfile.expects(:create!).raises(ActiveRecord::RecordNotUnique.new('duplicate user_id'))

    result = tool.execute(platform: 'youtube', handle: 'handle_novo')

    assert_equal :reactivated, result[:status]
    assert_nil winner.reload.archived_at
    assert_equal 'active', winner.monitoring_status
    assert_equal winner.id, result[:data][:id]
  end

  # ── 7. Deduplicação de channel ID (case sensível) ───────────────────────────

  test 'channel IDs que diferem apenas em caixa são tratados como perfis distintos' do
    create(:social_profile, platform: 'youtube', platform_username: 'UCn8SzhX6Z1qW9_123456789',
                            platform_user_id: 'UC_ORIG_ID', display_name: 'Original')
    create(:social_profile, platform: 'youtube', platform_username: 'UCN8SZHX6Z1QW9_123456789',
                            platform_user_id: 'UC_OTHER_ID', display_name: 'Outro case')

    tool = AddProfileTool.new
    dup = tool.send(:find_duplicate, 'youtube', 'UCn8SzhX6Z1qW9_123456789')
    assert_equal 'UCn8SzhX6Z1qW9_123456789', dup.platform_username

    dup_lower = tool.send(:find_duplicate, 'youtube', 'UCN8SZHX6Z1QW9_123456789')
    assert_equal 'UCN8SZHX6Z1QW9_123456789', dup_lower.platform_username
  end

  test 'find_profile diferencia channel IDs do YouTube por caixa exata em SetProfileMonitoringTool e RemoveProfileTool' do
    orig = create(:social_profile, platform: 'youtube', platform_username: 'UCn8SzhX6Z1qW9_123456789',
                                  platform_user_id: 'UCn8SzhX6Z1qW9_123456789', monitoring_status: 'active')
    other = create(:social_profile, platform: 'youtube', platform_username: 'UCN8SZHX6Z1QW9_123456789',
                                   platform_user_id: 'UCN8SZHX6Z1QW9_123456789', monitoring_status: 'active')

    set_tool = SetProfileMonitoringTool.new
    set_tool.execute(identifier: 'UCn8SzhX6Z1qW9_123456789', status: 'paused')

    assert_equal 'paused', orig.reload.monitoring_status
    assert_equal 'active', other.reload.monitoring_status

    remove_tool = RemoveProfileTool.new
    preview = remove_tool.execute(identifier: 'UCn8SzhX6Z1qW9_123456789')
    assert_equal :confirmation_required, preview[:status]
    assert_equal 'UCn8SzhX6Z1qW9_123456789', preview[:data][:target][:platform_username]

    res = remove_tool.execute(identifier: 'UCn8SzhX6Z1qW9_123456789', confirm_token: preview[:data][:confirm_token])

    assert_equal :success, res[:status]
    refute SocialProfile.exists?(orig.id)
    assert SocialProfile.exists?(other.id)
  end

  test 'handle com deduplicação case-insensitive mantém comportamento existente' do
    create(:social_profile, platform: 'twitter', platform_username: 'casehandle')
    tool = AddProfileTool.new
    dup = tool.send(:find_duplicate, 'twitter', 'CaseHandle')
    assert_not_nil dup
    assert_equal 'casehandle', dup.platform_username
  end
end
