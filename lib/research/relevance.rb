# frozen_string_literal: true

module Research
  module Relevance
    STOPWORDS = %w[
      the a an to for how is in of on and with from by at this that it my your
      i me we you what are do can its be or not no so if but about all just get
      has have was will
    ].freeze

    LOW_SIGNAL_TOKENS = %w[
      advice animation animations best chance chances code compare comparison
      differences explain guide guides how latest news odds opinion opinions
      prediction predictions probability probabilities prompt prompting prompts
      rate review reviews thoughts tip tips tutorial tutorials update updates
      use using versus vs worth
    ].freeze

    SYNONYMS = {
      "hip"        => %w[rap hiphop],
      "hop"        => %w[rap hiphop],
      "rap"        => %w[hip hop hiphop],
      "hiphop"     => %w[rap hip hop],
      "js"         => %w[javascript],
      "javascript" => %w[js],
      "ts"         => %w[typescript],
      "typescript" => %w[ts],
      "ai"         => %w[artificial intelligence],
      "ml"         => %w[machine learning],
      "react"      => %w[reactjs],
      "reactjs"    => %w[react],
      "svelte"     => %w[sveltejs],
      "sveltejs"   => %w[svelte],
      "vue"        => %w[vuejs],
      "vuejs"      => %w[vue]
    }.freeze

    RELEVANCE_FLOOR = 0.1

    PreparedQuery = Struct.new(:raw, :tokens, :informative_tokens, :normalized_phrase) do
      def self.build(query)
        raw = query.to_s.strip
        tokens = Relevance.tokenize(raw)
        informative = tokens.reject { |t| LOW_SIGNAL_TOKENS.include?(t) }
        norm_phrase = Relevance.normalize_phrase(raw)
        new(raw, tokens, informative, norm_phrase)
      end
    end

    def self.tokenize(text)
      return [] if text.nil?

      raw_words = text.to_s.downcase.gsub(/[^a-z0-9\s]/, " ").split
      tokens = []

      raw_words.each do |word|
        next if word.length <= 1 || STOPWORDS.include?(word)

        tokens << word
        if SYNONYMS.key?(word)
          SYNONYMS[word].each { |syn| tokens << syn }
        end
      end

      tokens.uniq
    end

    def self.normalize_phrase(text)
      return "" if text.nil?

      # Remove stopwords também aqui: a frase normalizada alimenta o phrase
      # bonus, e manter "the react" com stopword faria a mesma query com e sem
      # "the" pontuar diferente — o tokenize já as remove, a frase deve seguir
      # a mesma regra (paridade com o overlap).
      text.to_s.downcase.gsub(/[^a-z0-9\s]/, " ")
           .split.reject { |w| STOPWORDS.include?(w) || w.length <= 1 }
           .join(" ")
    end

    def self.token_overlap_relevance(query, text)
      pq = query.is_a?(PreparedQuery) ? query : PreparedQuery.build(query)
      return 0.5 if pq.raw.empty? || pq.tokens.empty?

      t_tokens = tokenize(text)
      return 0.0 if t_tokens.empty?

      overlap_tokens = pq.tokens & t_tokens
      overlap = overlap_tokens.size.to_f
      return 0.0 if overlap.zero?

      coverage = overlap / pq.tokens.size.to_f

      inf_overlap_tokens = pq.informative_tokens & t_tokens
      inf_count = inf_overlap_tokens.size
      inf_overlap = pq.informative_tokens.empty? ? 0.0 : inf_count.to_f / pq.informative_tokens.size.to_f

      denom = [t_tokens.size.to_f, pq.tokens.size.to_f + 4.0].min
      precision = overlap / denom

      norm_text = normalize_phrase(text)
      phrase_bonus = 0.0
      if !pq.normalized_phrase.empty? && norm_text.include?(pq.normalized_phrase)
        phrase_bonus = pq.normalized_phrase.split.size > 1 ? 0.12 : 0.16
      end

      base = 0.55 * (coverage**1.35) + 0.25 * inf_overlap + 0.20 * precision

      score = if inf_count.zero?
                [0.24, base].min
              else
                [1.0, base + phrase_bonus].min
              end

      score.round(2)
    end
  end
end
