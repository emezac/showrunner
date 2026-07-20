# frozen_string_literal: true

module Agentkit
  # Optional scheduled job for financial health monitoring.
  # Activated when :financial_health is in Agentkit.config.features.
  #
  # Analyzes LLM cost trends from AgentLog records and suggests
  # model routing optimizations if costs are above threshold.
  class FinancialHealthJob < ApplicationJob
    queue_as :agentkit_financial

    discard_on StandardError do |job, error|
      Rails.logger.error("[AgentKit::FinancialHealthJob] Failed: #{error.message}")
    end

    def perform
      return unless Agentkit.config.feature?(:financial_health)

      Rails.logger.info("[AgentKit::FinancialHealthJob] Financial health check started.")

      report = build_cost_report
      check_cost_thresholds(report)
    end

    private

    def build_cost_report
      logs = Agentkit::AgentLog.where(created_at: 30.days.ago..)

      {
        total_cost_usd:    Agentkit::AgentLog.total_cost_usd(logs),
        avg_cost_per_call: logs.average(:cost_usd)&.round(6),
        most_expensive_agent: logs.group(:agent_name)
                                  .sum(:cost_usd)
                                  .max_by { |_, v| v }&.first,
        total_calls: logs.count,
        failed_calls: logs.failed.count
      }
    end

    def check_cost_thresholds(report)
      monthly_budget = Agentkit.config.respond_to?(:monthly_llm_budget_usd) ?
        Agentkit.config.monthly_llm_budget_usd : nil

      return unless monthly_budget && report[:total_cost_usd] > monthly_budget * 0.8

      # Warn admin users via a high-priority suggestion
      admin_user = User.first # simplified
      return unless admin_user

      Agentkit::HITLEngine.suggest!(
        type:         "cost_alert",
        title:        "LLM cost approaching monthly budget",
        description:  "Last 30 days: $#{report[:total_cost_usd]} / $#{monthly_budget} budget. " \
                      "Most expensive agent: #{report[:most_expensive_agent]}.",
        priority:     "high",
        source_agent: self.class.name,
        user:         admin_user,
        payload:      report
      )
    end
  end
end
