require "json"
require "ostruct"

module Aflow
  module MCP
    module Protocol
      module JSONRPC
        def self.parse(json)
          data = JSON.parse(json)
          OpenStruct.new(
            id: data["id"],
            method: data["method"],
            params: data["params"] || {}
          )
        end

        def self.response(id:, result:)
          {
            jsonrpc: "2.0",
            id: id,
            result: result
          }.to_json
        end
        
        def self.error(id:, code:, message:)
          {
            jsonrpc: "2.0",
            id: id,
            error: {
              code: code,
              message: message
            }
          }.to_json
        end
      end
    end
  end
end
