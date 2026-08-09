# frozen_string_literal: true

module Llm
  class PromptLoader
    PROMPTS_DIR = Rails.root.join('config/prompts')
    PARTIALS_DIR = PROMPTS_DIR.join('partials')

    class PromptNotFoundError < ArgumentError; end

    class << self
      def load(name, **locals)
        file_path = PROMPTS_DIR.join("system/#{name}.yml")
        raise PromptNotFoundError, "Prompt '#{name}' não encontrado em #{file_path}" unless file_path.exist?

        raw = file_path.read
        yaml = YAML.safe_load(raw, permitted_classes: [Symbol])

        system_text = render_system(yaml['system'])
        user_text = render_template(yaml['user_template'], **locals)

        {
          system: system_text.strip,
          user: user_text.strip
        }
      end

      def partial(name)
        file_path = PARTIALS_DIR.join("_#{name}.yml")
        return '' unless file_path.exist?

        yaml = YAML.safe_load(file_path.read, permitted_classes: [Symbol])
        content = yaml['content'].to_s
        ERB.new(content).result(binding)
      end

      private

      # Renderiza o bloco `system:` com ERB completo.
      # Dá suporte a `<%= Llm::PromptLoader.partial('nome') %>` e também a tags
      # de controle (`<% if %>`, `<% end %>`) necessárias para conditionais de
      # feature flag (ex.: bullets sobre `page_fetch` condicionados a ENABLE_PAGE_FETCH).
      def render_system(template)
        return '' if template.nil?

        ERB.new(template).result(binding)
      end

      def render_template(template, **locals)
        return '' if template.nil?

        b = binding
        locals.each { |k, v| b.local_variable_set(k, v) }
        ERB.new(template).result(b)
      end
    end
  end
end
