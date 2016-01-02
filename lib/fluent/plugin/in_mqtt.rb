module Fluent
  class MqttInput < Input
    Plugin.register_input('mqtt', self)

    config_param :port, :integer, :default => 1883
    config_param :bind, :string, :default => '127.0.0.1'
    config_param :topic, :string, :default => '#'
    config_param :format, :string, :default => 'json'
    config_param :bulk_trans, :bool, :default => true
    config_param :bulk_trans_sep, :string, :default => "\t"
    config_param :username, :string, :default => nil
    config_param :password, :string, :default => nil
    config_param :keep_alive, :integer, :default => 15
    config_param :ssl, :bool, :default => nil
    config_param :ca_file, :string, :default => nil
    config_param :key_file, :string, :default => nil
    config_param :cert_file, :string, :default => nil

    require 'mqtt'

    # Define `router` method of v0.12 to support v0.10 or earlier
    unless method_defined?(:router)
      define_method("router") { Fluent::Engine }
    end

    def configure(conf)
      super
      @bind ||= conf['bind']
      @topic ||= conf['topic']
      @bulk_trans ||= conf['bulk_trans']
      @bulk_trans_sep ||= conf['bulk_trans_sep']
      @port ||= conf['port']
      @username ||= conf['username']
      @password ||= conf['password']
      @keep_alive ||= conf['keep_alive']
      configure_parser(conf)
      init_retry_interval
    end

    def configure_parser(conf)
      @parser = Plugin.new_parser(conf['format'])
      @parser.configure(conf)
    end
    
    def init_retry_interval
      @retry_interval = 1
    end

    def increment_retry_interval
      @retry_interval = @retry_interval * 2
    end

    def sleep_retry_interval(e, message)
      $log.debug "#{message}"
      $log.debug "#{e.class}: #{e.message}"
      $log.debug "Retry in #{@retry_interval} sec"
      sleep @retry_interval
      increment_retry_interval
    end

    def start
      $log.debug "start mqtt #{@bind}"
      opts = {
        host: @bind,
        port: @port,
        username: @username,
        password: @password,
        keep_alive: @keep_alive
      }
      opts[:ssl] = @ssl if @ssl
      opts[:ca_file] = @ca_file if @ca_file
      opts[:cert_file] = @cert_file if @cert_file
      opts[:key_file] = @key_file if @key_file

      # In order to handle Exception raised from reading Thread
      # in MQTT::Client caused by network disconnection (during read_byte),
      # @connect_thread generates connection.
      @client = MQTT::Client.new(opts)
      @connect_thread = Thread.new do
        while (true)
          begin
            @client.disconnect if @client.connected?
            @client.connect
            @client.subscribe(@topic)
            @get_thread.kill if !@get_thread.nil? && @get_thread.alive?
            @get_thread = Thread.new do
              @client.get do |topic, message|
                emit(topic, message)
              end
            end
            init_retry_interval
            sleep
          rescue MQTT::ProtocolException => e
            sleep_retry_interval(e, "Protocol error occurs.")
            next
          rescue Timeout::Error => e
            sleep_retry_interval(e, "Timeout error occurs.")
            next
          rescue SystemCallError => e
            sleep_retry_interval(e, "System call error occurs.")
            next
          rescue StandardError=> e
            sleep_retry_interval(e, "The other error occurs.")
            next
          end
        end
      end
    end

    def parse(message)
      @parser.parse(message) do |time, record|
        if time.nil?
          $log.debug "Since time_key field is nil, Fluent::Engine.now is used."
          time = Fluent::Engine.now
        end
        $log.debug "#{topic}, #{time}, #{record}"
        return [time, record]
      end
    end

    def emit(topic, message)
      begin
        topic.gsub!("/","\.")
        if @bulk_trans
          message.split(@bulk_trans_sep).each do |m|
            router.emit(topic, *parse(m))
          end
        else
          router.emit(topic, *parse(message))
        end
      rescue Exception => e
        $log.error :error => e.to_s
        $log.debug_backtrace(e.backtrace)
      end
    end

    def shutdown
      @get_thread.kill
      @connect_thread.kill
      @client.disconnect
    end
  end
end
