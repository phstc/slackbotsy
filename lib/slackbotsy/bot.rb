require 'net/http'
require 'net/https'
require 'uri'
require 'json'
require 'set'

module Slackbotsy

  class Bot

    attr_accessor :commands, :last_description

    def initialize(options)
      @options = options

      ## use set of tokens for (more or less) O(1) lookup on multiple channels
      @options['outgoing_token'] = Array(@options['outgoing_token']).to_set
      @commands = []
      setup_incoming_webhook    # http connection for async replies
      setup_help                # botsy help
      yield if block_given?     # run any hear statements in block
    end

    ## setup http connection for sending async incoming webhook messages to slack
    def setup_incoming_webhook
      @uri  = URI.parse "https://#{@options['team']}.slack.com/services/hooks/incoming-webhook?token=#{@options['incoming_token']}"
      @http = Net::HTTP.new(@uri.host, @uri.port)
      @http.use_ssl = true
      @http.verify_mode = OpenSSL::SSL::VERIFY_PEER
    end

    ## raw post of hash to slack
    def post(options)
      payload = {
        username: @options['name'],
        channel:  @options['channel']
      }.merge(options)
      payload[:channel] = payload[:channel].gsub(/^#?/, '#') #slack api needs leading # on channel
      request = Net::HTTP::Post.new(@uri.request_uri)
      request.set_form_data(payload: payload.to_json)
      @http.request(request)
      return nil # so as not to trigger text in outgoing webhook reply
    end

    ## simple wrapper on post to send text
    def say(text, options = {})
      post({ text: text }.merge(options))
    end

    ## simple wrapper on post to send attachment(s)
    def attach(ary, options = {})
      attachments = ary.is_a?(Array) ? ary : [ ary ] #force first arg to array
      post({ attachments: attachments }.merge(options))
    end

    ## add regex to things to hear
    def hear(regex, &block)
      ## allow multiple commands with the same regex
      commands << OpenStruct.new(regex: regex, description: get_description, proc: block)
    end

    def desc(description)
      @last_description = description
    end

    def get_description
      desc = @last_description
      @last_description = nil
      desc
    end

    def setup_help
      ## -v verbose desc => regex
      hear /^help(\s\-.)?$/ do |mdata|
        @caller.commands.reject { |cmd| cmd.description.nil? }.
          map do |cmd|
          if mdata[1].to_s.strip == '-v'
            "#{cmd.description} => #{cmd.regex.inspect}"
          else
            cmd.description
          end
        end
      end
    end

    ## pass list of files containing hear statements, to be opened and evaled
    def eval_scripts(*files)
      files.flatten.each do |file|
        self.instance_eval File.open(file).read
      end
    end

    ## check message and run blocks for any matches
    def handle_item(msg)
      return nil unless @options['outgoing_token'].include? msg[:token] # ensure messages are for us from slack
      return nil if msg[:user_name] == 'slackbot'  # do not reply to self
      return nil unless msg[:text].is_a?(String) # skip empty messages

      ## loop things to look for and collect immediate responses
      ## rescue everything here so the bot keeps running even with a broken script
      responses = commands.map do |cmd|
        if mdata = msg[:text].strip.match(cmd.regex)
          begin
            Slackbotsy::Message.new(self, msg).instance_exec(mdata, &cmd.proc)
          rescue => err
            err
          end
        end
      end

      ## format any replies for http response
      if responses
        { text: responses.compact.join("\n") }.to_json
      end
    end

  end

end
