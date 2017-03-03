require "secure_random"

module Raven
  class Event
    enum Severity
      DEBUG
      INFO
      WARNING
      ERROR
      FATAL
    end

    # A string representing the platform the SDK is submitting from.
    #
    # This will be used by the Sentry interface to customize
    # various components in the interface.
    PLATFORM = "crystal"

    # Information about the SDK sending the event.
    SDK = {name: "raven.cr", version: Raven::VERSION}

    # Hexadecimal string representing a uuid4 value.
    #
    # NOTE: The length is exactly 32 characters (no dashes!)
    property id : String

    # Indicates when the logging record was created (in the Sentry SDK).
    property timestamp : Time

    # The record severity. Defaults to `Severity::ERROR`.
    property level : Event::Severity?

    # The name of the logger which created the record.
    property logger : String?

    # The name of the transaction (or culprit) which caused this exception.
    property culprit : String?

    # Identifies the host SDK from which the event was recorded.
    property server_name : String?

    # The release version of the application.
    #
    # NOTE: This value will generally be something along the lines of
    # the git SHA for the given project.
    property release : String?

    # An array of strings used to dictate the deduplication of this event.
    #
    # NOTE: A value of `{{ default }}` will be replaced with the built-in behavior,
    # thus allowing you to extend it, or completely replace it.
    property fingerprint : Array(String)?

    # The environment name, such as `production` or `staging`.
    property environment : String?

    # A list of relevant modules and their versions.
    property modules : Hash(String, String)?

    property context : Context
    property configuration : Configuration
    property breadcrumbs : BreadcrumbBuffer

    any_json_property :contexts, :user, :tags, :extra

    def self.from(exc : Exception, **options)
      configuration = options[:configuration]? || Raven.configuration
      # Try to prevent error reporting loops
      if exc.is_a?(Raven::Error)
        configuration.logger.debug "Refusing to capture Raven error: #{exc.inspect}"
        return
      end
      if configuration.excluded_exceptions.includes?(exc.class.name)
        configuration.logger.debug "User excluded error: #{exc.inspect}"
        return
      end

      new(**options).tap do |event|
        # Messages limited to 10kb
        event.message = "#{exc.class}: #{exc.message}".byte_slice(0, 9_999)

        exception_context = get_exception_context(exc)
        event.extra.reverse_merge! exception_context

        # FIXME?
        exc.callstack ||= CallStack.new
        add_exception_interface(event, exc)
      end
    end

    def self.from(message : String, **options)
      # Messages limited to 10kb
      message = message.byte_slice(0, 9_999)

      new(**options).tap do |event|
        event.message = {message, options[:message_params]?}
      end
    end

    protected def self.get_exception_context(exc)
      exc.__raven_context
    end

    protected def self.add_exception_interface(event, exc)
      exceptions = [exc] of Exception
      context = Set(UInt64).new [exc.object_id]
      backtraces = Set(UInt64).new

      while exc = exc.cause
        break if context.includes?(exc.object_id)
        exceptions << exc
        context << exc.object_id
      end
      exceptions.reverse!

      values = exceptions.map do |e|
        Interface::SingleException.new do |iface|
          iface.type = e.class.to_s
          iface.value = e.to_s
          iface.module = e.class.to_s.split("::")[0...-1].join("::")

          iface.stacktrace =
            if e.backtrace? && !backtraces.includes?(e.backtrace.object_id)
              backtraces << e.backtrace.object_id
              Interface::Stacktrace.new do |stacktrace|
                stacktrace_interface_from stacktrace, event, e.backtrace
              end
            end
        end
      end
      event.interface :exception, values: values
    end

    protected def self.stacktrace_interface_from(iface, event, backtrace)
      iface.frames = [] of Interface::Stacktrace::Frame

      backtrace = Backtrace.parse(backtrace)
      backtrace.lines.reverse_each do |line|
        iface.frames << Interface::Stacktrace::Frame.new.tap do |frame|
          frame.abs_path = line.file
          frame.function = line.method
          frame.lineno = line.number
          frame.colno = line.column
          frame.in_app = line.in_app?
        end
      end

      event.culprit = get_culprit(iface.frames)
    end

    protected def self.get_culprit(frames)
      lastframe = frames.reverse.find(&.in_app?) || frames.last
      return unless lastframe
      parts = {
        [nil, lastframe.filename],
        ["in", lastframe.function],
        ["at line", lastframe.lineno],
      }
      msg = parts.reject(&.last.nil?).flatten.compact.join ' '
    end

    def initialize(**options)
      @interfaces = {} of Symbol => Interface
      @configuration = options[:configuration]? || Raven.configuration
      @breadcrumbs = options[:breadcrumbs]? || Raven.breadcrumbs
      @context = options[:context]? || Raven.context
      @id = SecureRandom.uuid.delete('-')
      @timestamp = Time.now
      @server_name = @configuration.server_name
      @release = @configuration.release
      @environment = @configuration.current_environment
      @modules = list_shard_specs if @configuration.send_modules?

      initialize_with **options

      contexts.merge! @context.contexts
      user.merge! @context.user
      extra.merge! @context.extra
      tags.merge! @configuration.tags, @context.tags
    end

    def initialize_with(**attributes)
      {% for var in @type.instance_vars %}
        if %arg = attributes[:{{var.name.id}}]?
          @{{var.name.id}} = %arg if %arg.is_a?({{var.type.id}})
        end
      {% end %}
      {% for method in @type.methods.select { |m| m.name.ends_with?('=') && m.args.size == 1 } %}
        {% ivar_name = method.name[0...-1].id %}
        if %arg = attributes[:{{ivar_name}}]?
          self.{{ivar_name}} = %arg
        end
      {% end %}
      self
    end

    def message
      interface(:message).try &.as(Interface::Message).unformatted_message
    end

    def message=(message : String)
      interface :message, message: message
    end

    def message=(message_with_params)
      options = {
        message: message_with_params.first,
        params:  message_with_params.last,
      }
      interface :message, **options
    end

    def backtrace=(backtrace)
      interface :stacktrace do |iface|
        self.class.stacktrace_interface_from iface.as(Interface::Stacktrace), self, backtrace
      end
    end

    def list_shard_specs
      shards_list = Raven.sys_command_compiled("shards list")
      deps = shards_list.scan /\* (?<name>.+?) \((?<version>.+?)\)/m
      unless deps.empty?
        deps.map { |match| {match["name"], match["version"]} }.to_h
      end
    end

    def interface(name : Symbol)
      interface = Interface[name]
      @interfaces[interface.sentry_alias]?
    end

    def interface(name : Symbol, **options : Object)
      interface = Interface[name]
      @interfaces[interface.sentry_alias] = interface.new(**options)
    end

    def interface(name : Symbol, options : NamedTuple)
      interface(name, **options)
    end

    def interface(name : Symbol, **options, &block)
      interface = Interface[name]
      @interfaces[interface.sentry_alias] = interface.new(**options) do |iface|
        yield iface
      end
    end

    def interface(name : Symbol, options : NamedTuple, &block)
      interface(name, **options) { |iface| yield iface }
    end

    def to_hash
      data = {
        event_id:    @id,
        timestamp:   @timestamp.to_utc.to_s("%FT%X"),
        level:       @level.try(&.to_s.downcase),
        platform:    PLATFORM,
        sdk:         SDK,
        logger:      @logger,
        culprit:     @culprit,
        server_name: @server_name,
        release:     @release,
        environment: @environment,
        fingerprint: @fingerprint,
        modules:     @modules,
        extra:       extra.to_h,
        tags:        tags.to_h,
        user:        user.to_h,
        contexts:    contexts.to_h,
        breadcrumbs: @breadcrumbs.size > 0 ? @breadcrumbs.to_hash : nil,
        message:     message,
      }.to_any_json

      @interfaces.each do |name, interface|
        data[name] = interface.to_hash
      end
      data.compact!
      data.to_h
    end
  end
end