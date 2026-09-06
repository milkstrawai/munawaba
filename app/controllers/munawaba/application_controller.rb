# frozen_string_literal: true

module Munawaba
  class ApplicationController < Munawaba.config.parent_controller.constantize
    layout "munawaba/application"
    protect_from_forgery with: :exception
    before_action :authenticate_munawaba!
    before_action :authorize_munawaba!
    before_action :html_only!
    helper Munawaba::ApplicationHelper
    helper_method :munawaba_theme

    private

    def authenticate_munawaba!
      callback = Munawaba.config.authenticate
      allowed = callback&.call(self)
      head :unauthorized unless performed? || allowed == true
    end

    def html_only!
      head :not_acceptable unless request.format.html?
    end

    def authorize_munawaba!
      capability, record = authorization_target
      allowed = Munawaba.config.authorize&.call(self, capability, record)
      head :forbidden unless performed? || allowed == true
    end

    def actor
      Munawaba.config.actor&.call(self)
    end

    def record_parameters(name)
      value = params.require(name)
      raise ActionController::ParameterMissing, name unless value.is_a?(ActionController::Parameters)

      value
    end

    def array_parameter(name)
      value = params[name]
      return [] if value.nil?
      unless value.is_a?(Array) && value.all? { |entry| entry.is_a?(String) || entry.is_a?(Integer) }
        raise ActionController::ParameterMissing, name
      end

      value
    end

    def scalar_parameter(name)
      value = params[name]
      raise ActionController::ParameterMissing, name unless value.nil? || value.is_a?(String)

      value
    end

    def munawaba_theme
      cookies[:munawaba_theme] == "light" ? "light" : "dark"
    end

    def command(operation, subject, attributes = {}, success_path:, template:)
      result = Commands.call(operation: operation, subject: subject, attributes: attributes,
                             actor: actor, token: params[:proposal_token], acknowledge_conflicts: params[:acknowledge_conflicts] == "1")
      if result.success?
        redirect_to success_path.respond_to?(:call) ? success_path.call(result.record) : success_path,
                    status: :see_other, notice: "Changes saved."
      else
        @errors = Array(result.errors)
        @preview = result.preview
        @record = result.record if result.record
        @stale = result.status == 409
        yield(result) if block_given?
        render template, status: result.status
      end
    end

    def proposal(operation, subject, attributes = {})
      @operation, @subject, @attributes = operation, subject, attributes
      result = Commands.preview(operation: operation, subject: subject, attributes: attributes, actor: actor)
      @preview = result.preview
      @errors = Array(result.errors)
      if @preview.nil? && operation.to_sym == :override
        @people = Person.where(active: true).order(:name)
        render "munawaba/overrides/new", status: result.status
        return
      end
      render "munawaba/shared/proposal", status: result.status
    end

    def refresh_proposal(operation, subject, attributes)
      @operation, @subject, @attributes = operation, subject, attributes
      unless @preview
        refreshed = Commands.preview(operation: operation, subject: subject, attributes: attributes, actor: actor)
        @preview = refreshed.preview
      end
      if @preview&.details
        details = @preview.details
        @operation = details[:operation].to_sym if details[:operation]
        @attributes = @attributes.merge(boundary_index: details[:boundary_index]) if @operation == :resume && details.key?(:boundary_index)
      end
    end

    def page_size
      50
    end

    def before_cursor(scope, column)
      return scope if params[:before].blank?

      stamp, id = params[:before].to_s.split("|", 2)
      time = Time.iso8601(stamp)
      raise ArgumentError unless id&.match?(/\A\d+\z/)
      raise ArgumentError unless %w[created_at occurred_at].include?(column)

      table = scope.klass.arel_table
      left = Arel::Nodes::Grouping.new([table[column], table[:id]])
      right = Arel::Nodes::Grouping.new([Arel::Nodes.build_quoted(time), Arel::Nodes.build_quoted(id.to_i)])
      scope.where(left.lt(right))
    rescue ArgumentError
      scope.none
    end

    def after_name_cursor(scope)
      cursor = scalar_parameter(:after)
      return scope if cursor.blank?
      raise ArgumentError if cursor.bytesize > 1024

      name, id = JSON.parse(Base64.urlsafe_decode64(cursor))
      raise ArgumentError unless name.is_a?(String) && name.length <= 120 && id.is_a?(Integer) && id.positive?

      scope.where("(#{scope.klass.table_name}.name, #{scope.klass.table_name}.id) > (?, ?)", name, id)
    rescue ArgumentError, JSON::ParserError
      scope.none
    end

    def computed_roster(schedule, memberships)
      rows = memberships.to_a
      return rows unless %w[active scheduled].include?(schedule.state)

      next_shift = Shift.where(schedule_id: schedule.id, canceled_at: nil).where("starts_at > ?", Time.current).order(
        :starts_at, :id
      ).first
      index = rows.index { |membership| membership.person_id == next_shift&.base_person_id }
      index ? rows.rotate(index) : rows
    end
  end
end
