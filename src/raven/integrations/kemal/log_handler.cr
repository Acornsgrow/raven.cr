require "kemal"

module Raven
  module Kemal
    # Kemal logger capturing all sent messages and requests as breadcrumbs.
    # 
    # Optionally wraps another `::Kemal::BaseLogHandler` and forwards messages
    # to it.
    #
    # ```
    # Kemal.config.logger = Raven::Kemal::LogHandler.new(Kemal::CommonLogHandler.new)
    # # ...
    # Kemal.config.add_handler(...)
    # # ...
    # Kemal.run
    # ```
    class LogHandler < ::Kemal::BaseLogHandler
      property? log_messages = true
      property? log_requests = true

      @wrapped : ::Kemal::BaseLogHandler?

      def initialize(@wrapped = nil)
      end

      def next=(handler : HTTP::Handler | Proc | Nil)
        @wrapped.try(&.next=(handler)) || (@next = handler)
      end

      private def elapsed_text(elapsed)
        millis = elapsed.total_milliseconds
        millis >= 1 ? "#{millis.round(2)}ms" : "#{(millis * 1000).round(2)}µs"
      end

      def call(context)
        time = Time.now
        begin
          @wrapped.try(&.call(context)) || call_next(context)
        ensure
          if log_requests?
            elapsed = Time.now - time
            elapsed_text = elapsed_text(elapsed)

            message = {
              context.response.status_code, context.request.method,
              context.request.resource, elapsed_text
            }.join ' '

            Raven.breadcrumbs.record do |crumb|
              unless (200...400).includes? context.response.status_code
                crumb.level = Breadcrumb::Severity::ERROR
              end
              crumb.category = "kemal.request"
              crumb.message = message
            end
          end
          context
        end
      end

      def write(message)
        if log_messages?
          Raven.breadcrumbs.record do |crumb|
            crumb.category = "kemal"
            crumb.message = message.strip
          end
        end
        @wrapped.try &.write(message)
      end
    end
  end
end
