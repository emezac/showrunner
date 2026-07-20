module Aflow
  module MCP
    module Adapters
      class FlowAdapter
        def initialize(flow_name)
          @flow_name = flow_name
        end

        def call(params)
          # Note: Integrate with actual Aflow graph execution.
          # We assume Aflow.run resolves the registered flow.
          context, trace = if Aflow.respond_to?(:run)
                             Aflow.run(@flow_name, params)
                           else
                             # Default fallback if runner requires specific graph initialization
                             raise NotImplementedError, "Implement flow runner integration for: #{@flow_name}"
                           end

          {
            output: context.respond_to?(:to_h) ? context.to_h : context.data,
            trace: trace.respond_to?(:to_h) ? trace.to_h : trace.events
          }
        end
      end
    end
  end
end
