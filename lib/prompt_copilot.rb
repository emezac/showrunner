# frozen_string_literal: true

module PromptCopilot
  SUGGESTIONS_MAP = {
    /football|soccer|ball|match|stadium|penalty|championship/i => [
      "90th minute penalty",
      "unexpected underdog victory",
      "career threatening injury",
      "rivalry match showdown",
      "teammate betraying pass"
    ],
    /horse|stallion|gallop|stable|ride|rider|canyon/i => [
      "wild stallion chase",
      "sunset desert gallop",
      "mysterious dark rider",
      "broken stable escape",
      "majestic canyon jump"
    ],
    /space|planet|galaxy|star|alien|orbit|astronaut|cosmic/i => [
      "cosmic radiation storm",
      "alien signal decoded",
      "lost in deep orbit",
      "fuel tank depletion",
      "unknown planet landing"
    ],
    /detective|mystery|murder|secret|crime|noir|police|clue/i => [
      "hidden smoking gun",
      "double crossing partner",
      "midnight alley chase",
      "mysterious blackmail letter",
      "rainy street shadow"
    ],
    /horror|ghost|haunted|monster|dark|shadow|basement|creepy/i => [
      "flickering hallway light",
      "creepy basement noise",
      "unexplained cold draft",
      "shadow moving closer",
      "broken mirror reflection"
    ],
    /magic|wizard|dragon|spell|castle|crystal|sword/i => [
      "hidden ancient ruins",
      "forbidden spell cast",
      "glowing crystal cave",
      "legendary sword glowing",
      "mythical beast shadow"
    ],
    /action|fight|battle|explosion|chase|pursuit|escape/i => [
      "high speed pursuit",
      "rooftop leap escape",
      "ticking bomb countdown",
      "ambush in shadows",
      "betrayed by commander"
    ],
    /romance|love|heart|kiss|lover|marriage|goodbye/i => [
      "unexpected rainy kiss",
      "tearful train departure",
      "long lost lover return",
      "forbidden secret affair",
      "bittersweet final goodbye"
    ],
    /drama|sad|cry|betray|truth|family|lie|death/i => [
      "shattered family secret",
      "tragic double betrayal",
      "heartbreaking final promise",
      "tearful confession scene",
      "conquering deepest fear"
    ]
  }.freeze

  DEFAULT_SUGGESTIONS = [
    "Make it tragic",
    "Add a dark secret",
    "Increase the tension",
    "Reveal a betrayer",
    "Introduce a time limit",
    "Change the weather",
    "Show a sudden injury",
    "Add a silent stalker",
    "Introduce a tragic choice",
    "Add a sudden twist"
  ].freeze

  # Sugiere 3 ideas dinámicas de forma offline basándose en palabras clave
  def self.suggest_offline(prompt)
    prompt_text = prompt.to_s.downcase
    matched_pools = []

    SUGGESTIONS_MAP.each do |regex, pool|
      if prompt_text.match?(regex)
        matched_pools << pool
      end
    end

    # Si hay coincidencia de palabras clave, usamos su pool. Si hay varias, las unimos.
    suggestions = if matched_pools.any?
                    matched_pools.flatten.uniq.sample(3)
                  else
                    DEFAULT_SUGGESTIONS.sample(3)
                  end

    # Si por alguna razón la lista de arriba no llega a 3 elementos (muy raro) rellenamos
    while suggestions.size < 3
      extra = DEFAULT_SUGGESTIONS.sample
      suggestions << extra unless suggestions.include?(extra)
    end

    suggestions
  end
end
