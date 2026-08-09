# frozen_string_literal: true

require "test_helper"
require_relative "../../../../lib/fetcher/channels/registry"

class Fetcher::Channels::RegistryTest < ActiveSupport::TestCase
  FakeChannel = Module.new do
    def self.call(url:, response: nil)
      { url: url, title: "falso", content: "corpo", metadata: { "source" => "falso" } }
    end
  end

  setup do
    Fetcher::Channels::Registry.reset_config!
    Fetcher::Channels::Registry.stubs(:config).returns(
      "hosts"         => { "exemplo.test" => "falso" },
      "content_types" => { "application/rss+xml" => "falso" }
    )
    Fetcher::Channels::Registry.stubs(:resolve).with("falso").returns(FakeChannel)
  end

  teardown { Fetcher::Channels::Registry.reset_config! }

  test "casa host exato" do
    assert_equal FakeChannel, Fetcher::Channels::Registry.for_host("exemplo.test")
  end

  test "casa subdominio pelo sufixo" do
    assert_equal FakeChannel, Fetcher::Channels::Registry.for_host("www.exemplo.test")
  end

  test "nao casa sufixo parcial que nao e subdominio" do
    assert_nil Fetcher::Channels::Registry.for_host("naoexemplo.test")
  end

  test "host desconhecido nao tem canal" do
    assert_nil Fetcher::Channels::Registry.for_host("outro.test")
  end

  test "casa content-type ignorando charset e caixa" do
    assert_equal FakeChannel, Fetcher::Channels::Registry.for_content_type("Application/RSS+XML; charset=utf-8")
  end

  test "EXTRACT_CHANNELS=0 desliga o roteador inteiro" do
    ENV["EXTRACT_CHANNELS"] = "0"
    assert_nil Fetcher::Channels::Registry.for_host("exemplo.test")
    assert_nil Fetcher::Channels::Registry.for_content_type("application/rss+xml")
  ensure
    ENV.delete("EXTRACT_CHANNELS")
  end

  test "fingerprint muda quando a configuracao muda" do
    Fetcher::Channels::Registry.unstub(:config)
    Fetcher::Channels::Registry.reset_config!
    antes = Fetcher::Channels::Registry.fingerprint
    Fetcher::Channels::Registry.stubs(:raw_config_text).returns("hosts:\n  novo.test: falso\n")
    Fetcher::Channels::Registry.reset_config!
    refute_equal antes, Fetcher::Channels::Registry.fingerprint
  end
end
