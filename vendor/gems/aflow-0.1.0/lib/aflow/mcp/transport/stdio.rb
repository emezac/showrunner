module Aflow
  module MCP
    module Transport
      class Stdio
        def initialize(server)
          @server = server
        end

        def start
          while (line = STDIN.gets)
            next if line.strip.empty?
            response = @server.call(line)
            puts response
            STDOUT.flush
          end
        end
      end
    end
  end
end
