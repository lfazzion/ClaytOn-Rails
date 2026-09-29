# frozen_string_literal: true

require "test_helper"
require "rake"

class YtRakeTest < ActiveSupport::TestCase
  setup do
    # Mesmo padrão de x_desfazer_rake_test.rb: aplicação Rake nova por teste, só com yt.rake.
    Rake.application = Rake::Application.new
    load Rails.root.join("lib/tasks/yt.rake").to_s
    Rake::Task.define_task(:environment)
  end

  teardown do
    Rake.application = nil
    %w[CONSULTA LIMITE ID].each { |variavel| ENV.delete(variavel) }
  end

  def roda(task, env)
    env.each { |k, v| ENV[k] = v }
    saida = StringIO.new
    $stdout = saida
    status = begin
      Rake::Task[task].invoke
      0
    rescue SystemExit => e
      e.status
    ensure
      $stdout = STDOUT
      env.each_key { |k| ENV.delete(k) }
    end
    [status, JSON.parse(saida.string.lines.last)]
  end

  test "yt:feed devolve videos" do
    Fetcher::Channels::Youtube.expects(:feed).with(limit: 20).returns([{ "id" => "a" }])
    assert_equal [0, { "videos" => [{ "id" => "a" }] }], roda("yt:feed", {})
  end

  test "yt:buscar usa o search existente e devolve a forma do agente" do
    Fetcher::Channels::Youtube.expects(:search).with(query: "agents", limit: 10)
                              .returns([{ "url" => "https://www.youtube.com/watch?v=dQw4w9WgXcQ", "title" => "T",
                                          "channel" => "C", "duration_seconds" => nil }])
    assert_equal [0, { "videos" => [{ "id" => "dQw4w9WgXcQ", "titulo" => "T", "canal" => "C", "duracao" => nil,
                                      "url" => "https://www.youtube.com/watch?v=dQw4w9WgXcQ" }] }],
                 roda("yt:buscar", { "CONSULTA" => "agents" })
  end

  test "yt:assistir com id invalido sai erro tipado sem rede" do
    Fetcher::Channels::Youtube.expects(:assistir).never
    status, corpo = roda("yt:assistir", { "ID" => "0" })
    assert_equal 1, status
    assert_equal "ArgumentError", corpo["tipo"]
  end
end
