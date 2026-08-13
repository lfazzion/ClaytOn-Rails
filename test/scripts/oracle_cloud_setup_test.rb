# frozen_string_literal: true

require "test_helper"
require "open3"

# Valida o script scripts/oracle-cloud-setup.sh sem executá-lo:
# faz o parse estático das diretrizes que afetam segurança e operação.
class OracleCloudSetupTest < ActiveSupport::TestCase
  SCRIPT_PATH = Rails.root.join("scripts", "oracle-cloud-setup.sh").to_s

  def script_content
    @script_content ||= File.read(SCRIPT_PATH)
  end

  test "nao contem core_pattern apontando para /tmp" do
    assert_no_match(
      /kernel\.core_pattern\s*=\s*\/tmp\/core/,
      script_content,
      "core_pattern nao deve apontar para /tmp: dumps gravados em diretorio temporario sao inseguros"
    )
  end

  test "timer de limpeza de docker usa calendario dominical as 03:00" do
    assert_match(/OnCalendar=Sun \*\-\*\-\* 03:00:00/, script_content,
                 "OnCalendar deve ser 'Sun *-*-* 03:00:00' para domingos as 03:00")
  end
end
