# frozen_string_literal: true

require 'ferrum'

module ScrapingServices
  class FerrumScraperBase
    USER_AGENTS = [
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Safari/605.1.15',
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
    ].freeze

    BLOCKED_RESOURCES = %w[image font stylesheet media].freeze

    attr_reader :browser

    def initialize(proxy: nil, user_agent: nil)
      @proxy = proxy
      @user_agent = user_agent || USER_AGENTS.sample
      @browser = build_browser
    end

    def visit(url, wait_for: nil)
      browser.goto(url)
      wait_for_selector(wait_for) if wait_for
      random_delay
      true
    rescue Ferrum::StatusError, Ferrum::TimeoutError => e
      handle_http_error(e)
    end

    def execute_script(script)
      browser.evaluate(script)
    end

    def find_element(selector)
      browser.at_css(selector)
    end

    def find_elements(selector)
      browser.css(selector)
    end

    def close
      return unless @browser

      begin
        @browser.reset
      rescue StandardError => e
        Rails.logger.warn "[ScrapingServices::FerrumScraperBase] falha no browser.reset antes do quit: #{e.class}: #{e.message}"
      ensure
        begin
          @browser.quit
        rescue StandardError
          nil
        end
      end
    end

    private

    def random_delay
      sleep(rand(1.5..4.5))
    end

    def wait_for_selector(selector, timeout: 15)
      deadline = Time.now + timeout
      loop do
        break if browser.at_css(selector)
        raise Ferrum::TimeoutError, "Timeout esperando por #{selector}" if Time.now > deadline

        sleep(0.5)
      end
    end

    def handle_http_error(error)
      message = error.message.to_s
      RateLimitHandler.handle_error(error) if message.match?(/403|429|blocked|captcha/i)
      raise error
    end

    def build_browser
      opts = FerumConfig.browser_options.dup
      opts[:browser_options] = (opts[:browser_options] || {}).dup
      opts[:browser_options]['--user-agent'] = @user_agent
      opts[:browser_options]['--proxy-server'] = @proxy if @proxy
      opts[:window_size] = [1366, 768]

      Ferrum::Browser.new(**opts)
    end
  end
end
