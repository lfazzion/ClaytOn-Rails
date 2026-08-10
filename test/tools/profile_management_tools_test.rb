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
    ScrapeYoutubeJob.expects(:perform_later).with(kind_of(Integer)).returns(true)

    tool = AddProfileTool.new
    result = tool.execute(platform: 'youtube', handle: 'canalx')

    assert_equal :success, result[:status]
    assert_equal 'canalx', result[:data][:username]

    profile = SocialProfile.find_by(platform: 'youtube', platform_username: 'canalx')
    assert_not_nil profile
    assert_equal 'UC_REAL_CHANNEL_ID', profile.platform_user_id
    assert_equal 'active', profile.monitoring_status
    assert_equal 'Canal Real YouTube', profile.display_name
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
    ScrapeYoutubeJob.stubs(:perform_later)

    tool = AddProfileTool.new
    result = tool.execute(platform: 'youtube', handle: 'https://www.youtube.com/@CanalUrl')

    assert_equal :success, result[:status]
    assert_equal 'canalurl', result[:data][:username]
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
    profile = create(:social_profile, :twitter, platform_username: 'archived_monitored', archived_at: 2.days.ago, monitoring_status: 'paused')

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

  # R3 — token-boundary matching: confirming "ana" with a phrase that only
  # contains "ana_clara" must FAIL. The old include?('ana') wrongly matched
  # the substring inside "ana_clara".
  test 'remove_profile: confirmar ana com frase que menciona apenas ana_clara retorna error' do
    profile_ana = create(:social_profile, :twitter, platform_username: 'ana')
    create_list(:social_post, 1, social_profile: profile_ana)
    profile_ana_clara = create(:social_profile, :twitter, platform_username: 'ana_clara')

    tool = RemoveProfileTool.new

    Thread.current[:cleitin_turn] = 'turn_a'
    tool.execute(identifier: 'ana')

    Thread.current[:cleitin_turn] = 'turn_b'
    res = tool.execute(identifier: 'ana',
                       confirmation_phrase: 'confirmo a remoção de ana_clara')
    assert_equal :error, res[:status]
    assert_nil profile_ana.reload.archived_at
  end

  test 'remove_profile: username vazio nao remove mesmo com confirmo' do
    profile = create(:social_profile, :twitter, platform_username: 'to_remove_empty')
    tool = RemoveProfileTool.new

    Thread.current[:cleitin_turn] = 'turn_a'
    tool.execute(identifier: 'to_remove_empty')

    profile.update_columns(platform_username: '')

    Thread.current[:cleitin_turn] = 'turn_b'
    res = tool.execute(identifier: 'to_remove_empty',
                       confirmation_phrase: 'confirmo a remoção')
    assert_equal :error, res[:status]
    assert_nil profile.reload.archived_at
  end

  test 'remove_profile em dois turnos: primeiro pede confirmação e segundo arquiva' do
    profile = create(:social_profile, :twitter, platform_username: 'to_remove')
    create_list(:social_post, 3, social_profile: profile)
    create_list(:profile_snapshot, 2, social_profile: profile)

    tool = RemoveProfileTool.new

    # Turno 1
    Thread.current[:cleitin_turn] = 'turn_1111'
    res1 = tool.execute(identifier: profile.platform_username)
    assert_equal :success, res1[:status]
    assert_equal :confirmation_required, res1[:data][:status]
    assert_nil res1[:data][:confirm_token], 'confirm_token não deve ser retornado na data'
    assert_includes res1[:data][:resumo], '3 posts'
    assert_includes res1[:data][:resumo], '2 snapshots'
    assert_nil profile.reload.archived_at

    # Repetição no MESMO turno (turn 1): não deve executar
    res_same = tool.execute(identifier: profile.platform_username)
    assert_equal :success, res_same[:status]
    assert_equal :confirmation_required, res_same[:data][:status]
    assert_nil profile.reload.archived_at

    # Turno 2 (novo turn ID): executa SÓ com a frase literal de confirmação
    Thread.current[:cleitin_turn] = 'turn_2222'
    res2 = tool.execute(identifier: profile.platform_username, confirmation_phrase: 'confirmo a remoção de to_remove')
    assert_equal :success, res2[:status]
    assert_equal 'removed', res2[:data][:status]
    assert_not_nil profile.reload.archived_at
    assert_equal 'paused', profile.monitoring_status
    assert_equal 3, profile.social_posts.count
  end

  test 'remove_profile em turno diferente SEM confirmation_phrase NÃO remove' do
    profile = create(:social_profile, :twitter, platform_username: 'to_remove_sem_frase')

    tool = RemoveProfileTool.new

    Thread.current[:cleitin_turn] = 'turn_a'
    res1 = tool.execute(identifier: profile.platform_username)
    assert_equal :confirmation_required, res1[:data][:status]

    Thread.current[:cleitin_turn] = 'turn_b'
    res2 = tool.execute(identifier: profile.platform_username)

    assert_equal :error, res2[:status]
    assert_includes res2[:reason], 'Confirmação inválida'
    assert_nil profile.reload.archived_at
  end

  test 'remove_profile em turno diferente com frase sem a palavra confirmo NÃO remove' do
    profile = create(:social_profile, :twitter, platform_username: 'to_remove_sem_conf')

    tool = RemoveProfileTool.new

    Thread.current[:cleitin_turn] = 'turn_a'
    tool.execute(identifier: profile.platform_username)

    Thread.current[:cleitin_turn] = 'turn_b'
    res = tool.execute(identifier: profile.platform_username, confirmation_phrase: 'quero apagar o to_remove_sem_conf')

    assert_equal :error, res[:status]
    assert_nil profile.reload.archived_at
  end

  test 'remove_profile em turno diferente com frase citando OUTRO perfil NÃO remove' do
    profile = create(:social_profile, :twitter, platform_username: 'to_remove_alvo')
    outro = create(:social_profile, :twitter, platform_username: 'outro_canal')

    tool = RemoveProfileTool.new

    Thread.current[:cleitin_turn] = 'turn_a'
    tool.execute(identifier: profile.platform_username)

    Thread.current[:cleitin_turn] = 'turn_b'
    res = tool.execute(identifier: profile.platform_username, confirmation_phrase: 'confirmo a remoção de outro_canal')

    assert_equal :error, res[:status]
    assert_nil profile.reload.archived_at
    assert_not_nil outro
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
end
