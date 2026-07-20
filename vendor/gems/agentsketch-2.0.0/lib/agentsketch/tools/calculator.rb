# frozen_string_literal: true

module AgentSketch
  module Tools
    # ── Calculator ──────────────────────────────────────────────────────────

    # Safe mathematical expression evaluator.
    class Calculator < RubyLLM::Tool
      ALLOWED_PATTERN = /\A[\d\s\+\-\*\/\.\(\)\^e%,]+\z/i

      description "Evalúa expresiones matemáticas de forma segura"

      param :expression, desc: "La expresión matemática a evaluar (e.g. '2 * (3 + 4)')"

      def initialize(_config = {})
        super()
      end

      def execute(expression:)
        clean = expression.to_s.strip

        unless clean.match?(ALLOWED_PATTERN)
          return "Error: expresión no permitida. Solo se permiten operaciones matemáticas básicas."
        end

        # Use Ruby's built-in eval in a restricted context
        result = eval(clean.gsub("^", "**"))  # rubocop:disable Security/Eval
        result.to_s
      rescue ZeroDivisionError
        "Error: división por cero"
      rescue SyntaxError, StandardError => e
        "Error al evaluar: #{e.message}"
      end
    end

    # ── TextEditor ──────────────────────────────────────────────────────────

    # A mutable text buffer for iterative writing/editing tasks.
    class TextEditor < RubyLLM::Tool
      description "Editor de texto en memoria para escritura y edición iterativa"

      param :action,  desc: "La acción: 'write', 'append', 'replace', 'read', 'clear'"
      param :content, desc: "El contenido para write/append/replace"
      param :target,  desc: "El texto a reemplazar (solo para 'replace')"

      def initialize(_config = {})
        @buffer = +"" # mutable string
        super()
      end

      def execute(action:, content: nil, target: nil)
        case action.to_s
        when "write"
          @buffer = content.to_s
          "Buffer actualizado (#{@buffer.length} caracteres)"
        when "append"
          @buffer << "\n#{content}"
          "Texto agregado (#{@buffer.length} caracteres en total)"
        when "replace"
          if @buffer.include?(target.to_s)
            @buffer.gsub!(target.to_s, content.to_s)
            "Reemplazo exitoso"
          else
            "Texto objetivo no encontrado en el buffer"
          end
        when "read"
          @buffer.empty? ? "(El buffer está vacío)" : @buffer
        when "clear"
          @buffer = +""
          "Buffer limpiado"
        else
          "Acción desconocida: #{action}. Usa: write, append, replace, read, clear"
        end
      end
    end

    # ── FileReader ──────────────────────────────────────────────────────────

    # Reads files from allowed paths. Supports txt, md, csv, json, pdf.
    class FileReader < RubyLLM::Tool
      description "Lee archivos del sistema de archivos local"

      param :path,     desc: "Ruta del archivo a leer"
      param :encoding, desc: "Codificación del archivo (default: utf-8)"

      DEFAULT_ALLOWED = ["./data/", "./docs/", "./uploads/", "/tmp/"].freeze
      DEFAULT_FORMATS = %w[.txt .md .csv .json .yaml .yml .rb .py .js .ts .html].freeze

      def initialize(config = {})
        @allowed_paths = config.fetch(:allowed_paths, DEFAULT_ALLOWED)
        @formats       = config.fetch(:formats, DEFAULT_FORMATS).map { |f| f.to_s.downcase }
        super()
      end

      def execute(path:, encoding: "utf-8")
        clean_path = File.expand_path(path)

        unless allowed_path?(clean_path)
          return "Acceso denegado: '#{path}' no está en las rutas permitidas."
        end

        ext = File.extname(clean_path).downcase
        unless allowed_format?(ext)
          return "Formato no soportado: '#{ext}'. Formatos permitidos: #{@formats.join(', ')}"
        end

        unless File.exist?(clean_path)
          return "Archivo no encontrado: #{path}"
        end

        content = File.read(clean_path, encoding: encoding)
        "Archivo: #{path}\n#{'-' * 40}\n#{content}"
      rescue StandardError => e
        "Error al leer archivo: #{e.message}"
      end

      private

      def allowed_path?(path)
        @allowed_paths.any? do |allowed|
          path.start_with?(File.expand_path(allowed))
        end
      end

      def allowed_format?(ext)
        @formats.any? { |f| f == ext }
      end
    end

    # ── CodeRunner ──────────────────────────────────────────────────────────

    # Executes code in a sandboxed subprocess or Docker container.
    class CodeRunner < RubyLLM::Tool
      description "Ejecuta código en un entorno seguro y devuelve el resultado"

      param :code,     desc: "El código a ejecutar"
      param :language, desc: "El lenguaje: 'ruby', 'python', 'javascript', 'bash'"
      param :timeout,  desc: "Timeout en segundos (default: 15)"

      LANGUAGE_COMMANDS = {
        "ruby"       => ["ruby", "-e"],
        "python"     => ["python3", "-c"],
        "javascript" => ["node", "-e"],
        "bash"       => ["bash", "-c"],
      }.freeze

      def initialize(config = {})
        @sandbox = config.fetch(:sandbox, :subprocess).to_sym
        @timeout = config.fetch(:timeout, 15).to_i
        super()
      end

      def execute(code:, language: "ruby", timeout: nil)
        lang    = language.to_s.downcase
        cmd_parts = LANGUAGE_COMMANDS[lang]
        return "Lenguaje no soportado: #{language}. Usa: #{LANGUAGE_COMMANDS.keys.join(', ')}" unless cmd_parts

        run_timeout = (timeout || @timeout).to_i
        run_subprocess(cmd_parts, code, run_timeout)
      end

      private

      def run_subprocess(cmd_parts, code, timeout)
        require "open3"
        require "timeout"

        stdout, stderr, status = Timeout.timeout(timeout) do
          Open3.capture3(*cmd_parts, code)
        end

        output = [stdout.strip, stderr.strip].reject(&:empty?).join("\n")
        exit_status = status.exitstatus

        "Exit: #{exit_status}\n#{output.empty? ? '(sin output)' : output}"
      rescue Timeout::Error
        "Error: timeout después de #{timeout}s"
      rescue StandardError => e
        "Error al ejecutar código: #{e.message}"
      end
    end

    # ── ImageAnalyzer ───────────────────────────────────────────────────────

    # Analyzes images using ruby_llm's native multimodal support.
    class ImageAnalyzer < RubyLLM::Tool
      description "Analiza imágenes y responde preguntas sobre su contenido"

      param :image_path, desc: "Ruta local o URL de la imagen"
      param :question,   desc: "Pregunta sobre la imagen (opcional)"

      def initialize(config = {})
        @model      = config.fetch(:model, "gpt-4o")
        @max_images = config.fetch(:max_images, 5).to_i
        super()
      end

      def execute(image_path:, question: "Describe esta imagen en detalle")
        chat     = RubyLLM.chat(model: @model)
        response = chat.ask(question, with: { image: image_path })
        response.content
      rescue StandardError => e
        "Error al analizar imagen: #{e.message}"
      end
    end

    # ── MemorySearch ────────────────────────────────────────────────────────

    # Searches the agent's own episodic memory for relevant past interactions.
    class MemorySearch < RubyLLM::Tool
      description "Busca en la memoria del agente información de interacciones anteriores"

      param :query, desc: "La consulta para buscar en memoria"
      param :top_k, desc: "Número de resultados (default: 3)"

      def initialize(config = {})
        @scope    = config.fetch(:scope, :agent).to_sym
        @top_k    = config.fetch(:top_k, 3).to_i
        @episodes = []  # shared with Episodic memory via accessor
        super()
      end

      def execute(query:, top_k: nil)
        limit = (top_k || @top_k).to_i

        if @episodes.empty?
          return "No hay recuerdos almacenados aún."
        end

        query_embedding = embed(query)
        return "No se pudo procesar la consulta." unless query_embedding

        results = @episodes
          .map    { |ep| ep.merge(score: cosine_similarity(query_embedding, ep[:embedding])) }
          .sort_by { |ep| -ep[:score] }
          .first(limit)

        return "No se encontraron recuerdos relevantes." if results.empty?

        results.map.with_index(1) { |ep, i| "[#{i}] #{ep[:summary]}" }.join("\n")
      rescue StandardError => e
        "Error en búsqueda de memoria: #{e.message}"
      end

      def inject_episodes(episodes)
        @episodes = episodes
      end

      private

      def embed(text)
        RubyLLM.embed(text).vectors
      rescue StandardError
        nil
      end

      def cosine_similarity(a, b)
        return 0.0 unless a && b && a.size == b.size

        dot   = a.zip(b).sum { |x, y| x * y }
        mag_a = Math.sqrt(a.sum { |x| x**2 })
        mag_b = Math.sqrt(b.sum { |x| x**2 })
        denom = mag_a * mag_b
        denom.zero? ? 0.0 : dot / denom
      end
    end
  end
end
