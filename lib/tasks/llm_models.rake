# frozen_string_literal: true

# lib/llm está fora do autoload (config.autoload_lib ignora 'llm').
require Rails.root.join('lib/llm/model_registry')

namespace :llm do
  namespace :models do
    desc 'Atualiza o registry de modelos com a lista viva dos provedores configurados'
    task refresh: :environment do
      total = Llm::ModelRegistry.refresh!
      puts "Registry atualizado: #{total} modelos."
    end

    desc 'Lista modelos gratuitos com tool calling (TOOLS_ONLY=false inclui os sem)'
    task free: :environment do
      tools_only = ENV['TOOLS_ONLY'].to_s.downcase != 'false'

      models = Llm::ModelRegistry.free(tools_only: tools_only)

      puts "\n#{models.size} modelos gratuitos#{' com tool calling' if tools_only}:\n\n"
      models.sort_by { |m| -m.context_window.to_i }.each do |model|
        puts format('  %<id>-55s ctx=%<ctx>s', id: model.id, ctx: model.context_window || '?')
      end
    end
  end
end
