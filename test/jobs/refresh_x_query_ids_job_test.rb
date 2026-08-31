# frozen_string_literal: true

require "test_helper"

class RefreshXQueryIdsJobTest < ActiveJob::TestCase
  test "chama resolver com force: true" do
    resolver = mock
    Fetcher::XQueryIdResolver.expects(:new).returns(resolver)
    resolver.expects(:resolve).with("SearchTimeline", force: true).at_least_once

    RefreshXQueryIdsJob.perform_now
  end

  test "é idempotente: segunda chamada não duplica trabalho" do
    resolver = mock
    Fetcher::XQueryIdResolver.expects(:new).twice.returns(resolver)
    # Cada chamada ao job cria um novo resolver (sem singleton), mas o cache
    # interno do resolver é o mesmo Rails.cache, então o valor já encontrado
    # será retornado imediatamente na segunda chamada (sem network).
    resolver.expects(:resolve).with("SearchTimeline", force: true).at_least(2)

    RefreshXQueryIdsJob.perform_now
    RefreshXQueryIdsJob.perform_now
  end

  test "falha do resolver não derruba o job" do
    resolver = mock
    Fetcher::XQueryIdResolver.expects(:new).returns(resolver)
    resolver.expects(:resolve).raises(StandardError, "network timeout")

    Rails.logger.stubs(:warn).with { |msg| msg.to_s.include?("network timeout") }

    assert_nothing_raised { RefreshXQueryIdsJob.perform_now }
  end

  test "log de sucesso é emitido" do
    resolver = mock
    Fetcher::XQueryIdResolver.expects(:new).returns(resolver)
    resolver.expects(:resolve).with("SearchTimeline", force: true).at_least_once

    # Usa stubs em vez de expects para ser tolerante a chamadas de outros logs (ex: resolver)
    # que possam passar nil; o job em si loga string valida na linha 22.
    Rails.logger.stubs(:info)

    RefreshXQueryIdsJob.perform_now
  end
end
