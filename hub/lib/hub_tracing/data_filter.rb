module HubTracing
  class DataFilter
    IDENTITY_KEYS = /\A(?:email|name|username|user_name|first_name|last_name|display_name|given_name|family_name|login)\z/i

    def initialize(include_sensitive_data: false)
      filters = Rails.application.config.filter_parameters
      if include_sensitive_data
        # Only the baseline email rule is relaxed; deployment-added filters still apply.
        filters = filters.reject { |filter| filter == :email || filter == "email" }
      else
        filters = filters + [ IDENTITY_KEYS ]
      end
      @filter = ActiveSupport::ParameterFilter.new(filters + [ :cookie ])
    end

    def job_arguments(arguments)
      serialized = ActiveJob::Arguments.serialize(arguments)
      JSON.generate(@filter.filter("arguments" => serialized).fetch("arguments"))
    end
  end
end
